import { existsSync } from "node:fs";
import { stat } from "node:fs/promises";
import {
  assertFfmpegAvailable,
  extractAudio,
  getDuration,
} from "../utils/ffmpeg.js";
import { warnIfUnsupportedContainer } from "../utils/paths.js";
import { detectSilences } from "../detect.js";
import { summarize } from "../segments.js";
import { render } from "../render.js";
import { formatDuration } from "../utils/time.js";
import {
  loadTokensFromTranscript,
  transcribeFromAudio,
} from "../retake/transcribe.js";
import { createGatewayClient, resolveGatewayEnv } from "../llm/gateway.js";
import { planLlmRetakeOps } from "../planners/llm-retake-planner.js";
import {
  buildEditPlan,
  loadPlan,
  planToKeepSegments,
  retakeOps,
  savePlan,
  type EditOperation,
  type EditPlan,
  type RemoveRetakeOp,
  type RemoveSilenceOp,
} from "../edit-plan.js";
import type { Segment, SmartcutConfig, Token } from "../types.js";
import type { PipelineEvent, Stage } from "./events.js";
import type { RetakeDecision } from "./decisions.js";

/**
 * The async generator that drives a smartcut run.
 *
 * Yields `PipelineEvent`s; consumers respond to `retakeProposed` by
 * calling `.next(decision)` with a `RetakeDecision`. All side effects
 * (spinners, prompts, printing) are the caller's responsibility.
 *
 * On unrecoverable failure, the generator yields an `error` event and
 * returns. On cancel, it returns silently after yielding any pending
 * cleanup events.
 */
export async function* runSmartcut(
  config: SmartcutConfig,
  whisperModel: string
): AsyncGenerator<PipelineEvent, void, RetakeDecision | undefined> {
  const overallStart = Date.now();
  const stageStarts = new Map<Stage, number>();

  function stageStart(stage: Stage, message?: string): PipelineEvent {
    stageStarts.set(stage, Date.now());
    return { type: "stage", stage, status: "start", message };
  }

  function stageDone(stage: Stage, message?: string): PipelineEvent {
    const start = stageStarts.get(stage);
    const durationMs = start != null ? Date.now() - start : undefined;
    return { type: "stage", stage, status: "done", message, durationMs };
  }

  function stageFail(stage: Stage, message: string): PipelineEvent {
    const start = stageStarts.get(stage);
    const durationMs = start != null ? Date.now() - start : undefined;
    return { type: "stage", stage, status: "fail", message, durationMs };
  }

  // -------------------------------------------------------------------------
  // Pre-flight: input file + ffmpeg + env.
  // -------------------------------------------------------------------------
  if (!existsSync(config.input)) {
    yield { type: "error", message: `Input file not found: ${config.input}` };
    return;
  }

  const containerWarn = warnIfUnsupportedContainer(config.input);
  if (containerWarn) {
    yield {
      type: "progress",
      stage: "probe",
      note: containerWarn,
    };
  }

  try {
    await assertFfmpegAvailable();
  } catch (err) {
    yield { type: "error", message: (err as Error).message, stage: "probe" };
    return;
  }

  // Validate LLM env up front (unless we're loading a saved plan).
  let gatewayEnv: ReturnType<typeof resolveGatewayEnv> | undefined;
  if (!config.planPath) {
    try {
      gatewayEnv = resolveGatewayEnv();
    } catch (err) {
      yield {
        type: "error",
        message: (err as Error).message,
        stage: "detect-retakes",
      };
      return;
    }
  }

  // -------------------------------------------------------------------------
  // Probe duration + emit metadata.
  // -------------------------------------------------------------------------
  yield stageStart("probe", "Probing file...");
  let duration: number;
  let sizeBytes = 0;
  try {
    duration = await getDuration(config.input);
    try {
      const s = await stat(config.input);
      sizeBytes = s.size;
    } catch {
      // best-effort
    }
    yield {
      type: "metadata",
      durationSec: duration,
      sizeBytes,
    };
    yield stageDone("probe", `Duration: ${formatDuration(duration)}`);
  } catch (err) {
    yield stageFail("probe", "Could not read file duration.");
    yield {
      type: "error",
      message: (err as Error).message,
      stage: "probe",
    };
    return;
  }

  let plan: EditPlan;

  // -------------------------------------------------------------------------
  // Path A: load a saved plan and skip detection.
  // -------------------------------------------------------------------------
  if (config.planPath) {
    try {
      plan = await loadPlan(config.planPath);
      yield {
        type: "progress",
        stage: "probe",
        note: `Loaded plan with ${plan.operations.length} operation(s).`,
      };
    } catch (err) {
      yield {
        type: "error",
        message: `Could not load plan: ${(err as Error).message}`,
      };
      return;
    }
  } else {
    // -----------------------------------------------------------------------
    // Path B: detect silence + retakes and build a fresh plan.
    // -----------------------------------------------------------------------
    yield stageStart("extract-audio", "Extracting audio...");
    let wavPath: string;
    let cleanupWav: () => Promise<void>;
    try {
      ({ wavPath, cleanup: cleanupWav } = await extractAudio(config.input));
      yield stageDone("extract-audio", "Audio extracted.");
    } catch (err) {
      yield stageFail("extract-audio", "Audio extraction failed.");
      yield {
        type: "error",
        message: (err as Error).message,
        stage: "extract-audio",
      };
      return;
    }

    try {
      // --- Coarse silence detection -------------------------------------
      yield stageStart("silence-coarse", "Detecting silence...");
      let silenceSegments: Segment[] = [];
      try {
        const result = await detectSilences(
          {
            input: config.input,
            output: config.output,
            thresholdDb: config.thresholdDb,
            minSilence: config.minSilence,
            leadInMs: 0,
            tailOutMs: 0,
            skipApproval: true,
            dryRun: false,
            crf: config.crf,
            preset: config.preset,
          },
          duration,
          wavPath
        );
        silenceSegments = result.silences;
        yield {
          type: "silenceFound",
          count: silenceSegments.length,
          segments: silenceSegments,
        };
        yield stageDone(
          "silence-coarse",
          `Found ${silenceSegments.length} silence region${silenceSegments.length !== 1 ? "s" : ""}.`
        );
      } catch (err) {
        yield stageFail("silence-coarse", "Silence detection failed.");
        yield {
          type: "error",
          message: (err as Error).message,
          stage: "silence-coarse",
        };
        return;
      }

      // --- Fine silences for retake boundary snapping -------------------
      yield stageStart("silence-fine", "Detecting fine-grained silences...");
      let snapSilences: Segment[] = [];
      try {
        const result = await detectSilences(
          {
            input: config.input,
            output: config.output,
            thresholdDb: -40,
            minSilence: 0.1,
            leadInMs: 0,
            tailOutMs: 0,
            skipApproval: true,
            dryRun: false,
            crf: config.crf,
            preset: config.preset,
          },
          duration,
          wavPath
        );
        snapSilences = result.silences;
        yield stageDone(
          "silence-fine",
          `Found ${snapSilences.length} snap point${snapSilences.length !== 1 ? "s" : ""}.`
        );
      } catch {
        // best-effort — non-fatal
        yield stageDone("silence-fine", "Snap detection skipped.");
      }

      // --- Transcribe ---------------------------------------------------
      const transcribeMsg = config.transcriptPath
        ? "Loading transcript..."
        : `Transcribing with whisper (model: ${whisperModel})...`;
      yield stageStart("transcribe", transcribeMsg);
      let tokens: Token[];
      try {
        if (config.transcriptPath) {
          tokens = await loadTokensFromTranscript(
            config.transcriptPath,
            config.fillerWords
          );
        } else {
          tokens = await transcribeFromAudio(wavPath, {
            model: whisperModel,
            saveTranscriptPath: config.saveTranscriptPath,
            fillerWords: config.fillerWords,
          });
        }
        const previewText = tokens
          .map((t) => t.word)
          .join(" ")
          .replace(/\s+/g, " ")
          .trim();
        yield {
          type: "transcript",
          tokenCount: tokens.length,
          preview: previewText,
        };
        yield stageDone(
          "transcribe",
          `Transcribed: ${tokens.length} word${tokens.length !== 1 ? "s" : ""}.`
        );
      } catch (err) {
        yield stageFail("transcribe", "Transcription failed.");
        yield {
          type: "error",
          message: (err as Error).message,
          stage: "transcribe",
        };
        return;
      }

      // --- LLM retake detection -----------------------------------------
      yield stageStart(
        "detect-retakes",
        `Detecting retakes with ${config.model} (via AI Gateway)...`
      );
      let retakeOperations: RemoveRetakeOp[];
      try {
        const client = createGatewayClient(gatewayEnv!);
        retakeOperations = await planLlmRetakeOps(
          client,
          config.model,
          tokens,
          snapSilences,
          config.maxRetakeRatio,
          config.passes
        );
        yield stageDone(
          "detect-retakes",
          `Found ${retakeOperations.length} retake${retakeOperations.length !== 1 ? "s" : ""}.`
        );
      } catch (err) {
        yield stageFail("detect-retakes", "Retake detection failed.");
        yield {
          type: "error",
          message: (err as Error).message,
          stage: "detect-retakes",
        };
        return;
      }

      const silenceOperations: RemoveSilenceOp[] = silenceSegments.map((s) => ({
        type: "removeSilence",
        start: s.start,
        end: s.end,
      }));

      const operations: EditOperation[] = [
        ...silenceOperations,
        ...retakeOperations,
      ];
      plan = buildEditPlan(config.input, duration, operations);
    } finally {
      await cleanupWav();
    }
  }

  // -------------------------------------------------------------------------
  // Persist plan if requested.
  // -------------------------------------------------------------------------
  if (config.savePlanPath) {
    try {
      await savePlan(config.savePlanPath, plan);
      yield {
        type: "progress",
        stage: "review",
        note: `Plan written to ${config.savePlanPath}`,
      };
    } catch (err) {
      yield {
        type: "progress",
        stage: "review",
        note: `Could not save plan: ${(err as Error).message}`,
      };
    }
  }

  // -------------------------------------------------------------------------
  // Review / approval loop.
  // -------------------------------------------------------------------------
  let finalPlan = plan;
  const allRetakes = retakeOps(plan);

  if (allRetakes.length > 0 && !config.skipApproval && !config.planPath) {
    yield stageStart("review", "Awaiting retake decisions...");
    const approved: RemoveRetakeOp[] = [];
    let cancelled = false;
    let approveRest = false;

    for (let i = 0; i < allRetakes.length; i++) {
      const op = allRetakes[i];
      const opId = `r-${i}`;

      if (approveRest) {
        approved.push(op);
        continue;
      }

      const decision = yield {
        type: "retakeProposed",
        opId,
        op,
        index: i,
        total: allRetakes.length,
      };

      if (!decision || decision.kind === "cancel") {
        cancelled = true;
        yield { type: "retakeDecision", opId, action: "keep" };
        break;
      }

      if (decision.kind === "keep") {
        yield { type: "retakeDecision", opId, action: "keep" };
        continue;
      }

      if (decision.kind === "approveRest") {
        approveRest = true;
        approved.push(op);
        yield { type: "retakeDecision", opId, action: "remove" };
        continue;
      }

      // remove
      approved.push(op);
      yield { type: "retakeDecision", opId, action: "remove" };
    }

    if (cancelled) {
      yield stageFail("review", "Cancelled.");
      return;
    }

    // Replace retake ops in the plan with only the approved set.
    const keptOps: EditOperation[] = plan.operations.filter(
      (op) => op.type !== "removeRetake"
    );
    finalPlan = {
      ...plan,
      operations: [...keptOps, ...approved],
    };
    yield stageDone(
      "review",
      `Approved ${approved.length} of ${allRetakes.length}.`
    );
  }

  // -------------------------------------------------------------------------
  // Compute keep segments.
  // -------------------------------------------------------------------------
  const keep = planToKeepSegments(finalPlan, config.leadInMs, config.tailOutMs);
  if (keep.length === 0) {
    yield {
      type: "error",
      message: "Nothing left to keep after applying the plan.",
    };
    return;
  }

  const summary = summarize(keep, duration);

  // -------------------------------------------------------------------------
  // Dry-run: skip render and emit `done`.
  // -------------------------------------------------------------------------
  if (config.dryRun) {
    yield {
      type: "done",
      plan: finalPlan,
      output: "",
      savedSec: summary.saved,
      savedPercent: summary.savedPercent,
      elapsedSec: (Date.now() - overallStart) / 1000,
    };
    return;
  }

  // -------------------------------------------------------------------------
  // Render.
  // -------------------------------------------------------------------------
  yield stageStart("render", "Rendering...");
  const renderStart = Date.now();

  // Buffer progress updates and yield them between the async ffmpeg events.
  // Generators can't yield from inside an arbitrary callback, so we collect
  // updates into a queue that we drain via a Promise.
  const progressQueue: PipelineEvent[] = [];
  let progressResolver: (() => void) | null = null;
  function flushProgress() {
    progressResolver?.();
    progressResolver = null;
  }

  const renderPromise = render(
    {
      input: config.input,
      output: config.output,
      thresholdDb: config.thresholdDb,
      minSilence: config.minSilence,
      leadInMs: config.leadInMs,
      tailOutMs: config.tailOutMs,
      skipApproval: true,
      dryRun: false,
      crf: config.crf,
      preset: config.preset,
    },
    keep,
    {
      onProgress: (p) => {
        progressQueue.push({
          type: "renderProgress",
          frame: p.frame,
          fps: p.fps,
          speed: p.speed,
          percent: p.percent,
          etaSec: p.etaSec,
        });
        flushProgress();
      },
    }
  ).then(
    () => ({ ok: true as const }),
    (err: unknown) => ({ ok: false as const, err })
  );

  let renderResult: { ok: true } | { ok: false; err: unknown } | null = null;
  renderPromise.then((r) => {
    renderResult = r;
    flushProgress();
  });

  while (renderResult === null || progressQueue.length > 0) {
    if (progressQueue.length > 0) {
      yield progressQueue.shift()!;
      continue;
    }
    if (renderResult !== null) break;
    await new Promise<void>((resolve) => {
      progressResolver = resolve;
    });
  }

  const result = renderResult as { ok: true } | { ok: false; err: unknown };
  if (!result.ok) {
    yield stageFail("render", "Render failed.");
    const err = result.err;
    yield {
      type: "error",
      message: err instanceof Error ? err.message : String(err),
      stage: "render",
      stack: err instanceof Error ? err.stack : undefined,
    };
    return;
  }

  yield stageDone(
    "render",
    `Render complete (${((Date.now() - renderStart) / 1000).toFixed(1)}s).`
  );

  yield {
    type: "done",
    plan: finalPlan,
    output: config.output,
    savedSec: summary.saved,
    savedPercent: summary.savedPercent,
    elapsedSec: (Date.now() - overallStart) / 1000,
  };
}
