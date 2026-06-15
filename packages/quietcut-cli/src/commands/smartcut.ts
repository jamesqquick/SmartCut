import { existsSync } from "node:fs";
import { resolve } from "node:path";
import chalk from "chalk";
import { Command } from "commander";
import ora, { type Ora } from "ora";
import {
  defaultSmartcutOutput,
  type PipelineEvent,
  planToKeepSegments,
  type RetakeDecision,
  retakeOps,
  runSmartcut,
  type SmartcutConfig,
  type Stage,
} from "quietcut-core";
import { formatDuration, printSmartcutPreview } from "./preview.js";
import { printCut, promptRetakeDecision } from "./review.js";

const DEFAULT_FILLER_WORDS = new Set([
  "um",
  "uh",
  "like",
  "so",
  "okay",
  "ok",
  "right",
  "yeah",
  "uh-huh",
  "uhh",
  "umm",
  "hmm",
  "hm",
  "er",
  "err",
]);

const DEFAULT_MODEL = "claude-opus-4-8";

// -----------------------------------------------------------------------------
// Stage labels mirror the original ora messages so the CLI feels unchanged.
// -----------------------------------------------------------------------------
const STAGE_LABELS: Record<Stage, string> = {
  probe: "Probing file",
  "extract-audio": "Extracting audio",
  "silence-coarse": "Detecting silence",
  "silence-fine": "Detecting fine silences",
  transcribe: "Transcribing",
  "detect-retakes": "Detecting retakes",
  review: "Reviewing retakes",
  render: "Rendering",
};

export const smartcutCommand = new Command("smartcut")
  .description(
    "AI-driven cut: remove silence and contextual retakes (LLM via Cloudflare AI Gateway)",
  )
  .argument("<input>", "Input video file")
  .option("-o, --output <path>", "Output file (default: <input>-smart.<ext>)")
  // silence options
  .option("-t, --threshold <dB>", "Silence threshold in dB", "-30")
  .option(
    "-d, --min-silence <seconds>",
    "Minimum silence duration to cut (seconds)",
    "0.6",
  )
  // llm options
  .option("--model <name>", "Claude model id", DEFAULT_MODEL)
  .option(
    "--max-retake-ratio <n>",
    "Drop cuts whose deleted-to-kept word ratio exceeds this (guards against mis-paired recurring phrases and looping transcripts)",
    "15",
  )
  .option(
    "--passes <n>",
    "Retake detection passes; later passes re-clean what earlier passes left behind (1 = single pass)",
    "2",
  )
  .option(
    "--whisper-model <name>",
    "Whisper model for transcription",
    "base.en",
  )
  .option(
    "--transcript <path>",
    "Reuse an existing whisper JSON transcript (skips transcription)",
  )
  .option(
    "--save-transcript <path>",
    "Write the whisper JSON transcript to this path after transcribing",
  )
  .option(
    "--log-transcript",
    "Print the full transcript text to the console before detecting retakes",
  )
  .option(
    "--plan <path>",
    "Load a saved EditPlan JSON and skip detection (re-render)",
  )
  .option("--save-plan <path>", "Write the EditPlan JSON after detection")
  // shared options
  .option(
    "-i, --lead-in <ms>",
    "Padding to keep before each segment (ms)",
    "300",
  )
  .option(
    "-O, --tail-out <ms>",
    "Padding to keep after each segment (ms)",
    "300",
  )
  .option("-y, --yes", "Skip approval/review and render immediately")
  .option("--dry-run", "Print the plan and exit without rendering")
  .option("--crf <n>", "x264 CRF quality (lower = better)", "18")
  .option("--preset <name>", "x264 preset", "medium")
  .action(async (inputArg: string, opts) => {
    const input = resolve(inputArg);

    if (!existsSync(input)) {
      console.error(chalk.red(`Error: input file not found: ${input}`));
      process.exit(1);
    }

    const output = opts.output
      ? resolve(opts.output)
      : defaultSmartcutOutput(input);

    const config: SmartcutConfig = {
      input,
      output,
      thresholdDb: parseFloat(opts.threshold),
      minSilence: parseFloat(opts.minSilence),
      model: opts.model,
      fillerWords: DEFAULT_FILLER_WORDS,
      maxRetakeRatio: parseFloat(opts.maxRetakeRatio),
      passes: parseInt(opts.passes, 10),
      transcriptPath: opts.transcript ? resolve(opts.transcript) : undefined,
      saveTranscriptPath: opts.saveTranscript
        ? resolve(opts.saveTranscript)
        : undefined,
      planPath: opts.plan ? resolve(opts.plan) : undefined,
      savePlanPath: opts.savePlan ? resolve(opts.savePlan) : undefined,
      leadInMs: parseInt(opts.leadIn, 10),
      tailOutMs: parseInt(opts.tailOut, 10),
      skipApproval: Boolean(opts.yes),
      dryRun: Boolean(opts.dryRun),
      crf: parseInt(opts.crf, 10),
      preset: opts.preset,
    };
    const whisperModel: string = opts.whisperModel;
    const logTranscript = Boolean(opts.logTranscript);

    // -------------------------------------------------------------------------
    // Drive the runSmartcut generator and translate events into CLI output.
    // -------------------------------------------------------------------------
    const gen = runSmartcut(config, whisperModel);
    let nextDecision: RetakeDecision | undefined;
    let currentSpinner: Ora | null = null;
    let currentSpinnerStage: Stage | null = null;
    let exitCode = 0;
    let errored = false;

    function ensureSpinner(stage: Stage, message: string): Ora {
      if (currentSpinner && currentSpinnerStage === stage) {
        currentSpinner.text = message;
        return currentSpinner;
      }
      if (currentSpinner) currentSpinner.stop();
      currentSpinner = ora(message).start();
      currentSpinnerStage = stage;
      return currentSpinner;
    }

    function finishSpinner(
      stage: Stage,
      kind: "succeed" | "fail",
      message: string,
    ): void {
      if (currentSpinner && currentSpinnerStage === stage) {
        currentSpinner[kind](message);
        currentSpinner = null;
        currentSpinnerStage = null;
      } else {
        // No matching spinner (e.g. event arrived after we already finished).
        console.log(
          kind === "succeed"
            ? chalk.green(`✔ ${message}`)
            : chalk.red(`✖ ${message}`),
        );
      }
    }

    try {
      while (true) {
        const { value, done } = await gen.next(nextDecision);
        nextDecision = undefined;
        if (done) break;
        const event = value as PipelineEvent;
        const action = await handleEvent(event);
        if (action && typeof action === "object" && "kind" in action) {
          nextDecision = action;
        }
      }
    } catch (err) {
      // TS narrows `currentSpinner` to `null` here because it can't track
      // mutations through the closure; cast back to the declared type.
      const spinner = currentSpinner as Ora | null;
      spinner?.fail("Aborted.");
      console.error(chalk.red((err as Error).message));
      exitCode = 1;
      errored = true;
    }

    if (errored) process.exit(exitCode);

    // -------------------------------------------------------------------------
    // Event handlers (closure over local state).
    // -------------------------------------------------------------------------
    async function handleEvent(
      event: PipelineEvent,
    ): Promise<RetakeDecision | void> {
      switch (event.type) {
        case "stage": {
          // Legacy CLI was silent about the fine-grained snap-silence step;
          // preserve that to keep terminal output equivalent.
          if (event.stage === "silence-fine") return;

          const label = STAGE_LABELS[event.stage] ?? event.stage;
          if (event.status === "start") {
            // Prefer the generator's per-stage message (e.g. "Transcribing
            // with whisper (model: base.en)...") to keep parity with legacy.
            ensureSpinner(event.stage, event.message ?? `${label}...`);
          } else if (event.status === "done") {
            finishSpinner(
              event.stage,
              "succeed",
              event.message ?? `${label} done.`,
            );
          } else {
            finishSpinner(
              event.stage,
              "fail",
              event.message ?? `${label} failed.`,
            );
          }
          return;
        }
        case "progress": {
          if (event.note) {
            const label = STAGE_LABELS[event.stage] ?? event.stage;
            if (currentSpinner && currentSpinnerStage === event.stage) {
              currentSpinner.text = `${label}... ${event.note}`;
            } else {
              console.log(chalk.dim(event.note));
            }
          }
          return;
        }
        case "metadata": {
          // The 'probe' stage spinner gets a friendlier message.
          if (currentSpinner && currentSpinnerStage === "probe") {
            currentSpinner.text = `Probing file... ${formatDuration(event.durationSec)}`;
          }
          return;
        }
        case "silenceFound": {
          // Count is also embedded in the stage 'done' message; nothing to print.
          return;
        }
        case "transcript": {
          if (logTranscript) {
            console.log();
            console.log(chalk.bold("Transcript:"));
            console.log(chalk.dim(event.preview));
            console.log();
          }
          return;
        }
        case "retakeProposed": {
          // Pause the review spinner while the user makes a choice.
          if (currentSpinner) {
            currentSpinner.stop();
            currentSpinner = null;
            currentSpinnerStage = null;
          }
          printCut(event.op, event.index, event.total);
          const decision = await promptRetakeDecision();
          return decision;
        }
        case "retakeDecision": {
          // No-op for the CLI; we already printed the prompt.
          return;
        }
        case "renderProgress": {
          if (!currentSpinner || currentSpinnerStage !== "render") return;
          const bits: string[] = [];
          if (event.percent != null) bits.push(`${event.percent.toFixed(1)}%`);
          if (event.fps != null) bits.push(`${event.fps.toFixed(1)}fps`);
          if (event.speed != null) bits.push(`${event.speed.toFixed(2)}x`);
          if (event.etaSec != null && Number.isFinite(event.etaSec)) {
            bits.push(`ETA ${formatDuration(event.etaSec)}`);
          }
          currentSpinner.text = `Rendering... ${bits.join("  ")}`;
          return;
        }
        case "done": {
          // Compute keep segments and print the preview from the final plan.
          const keep = planToKeepSegments(
            event.plan,
            config.leadInMs,
            config.tailOutMs,
          );
          printSmartcutPreview(event.plan, keep, event.plan.duration, input);

          if (event.output === "") {
            console.log(
              chalk.dim("--dry-run specified. Exiting without rendering."),
            );
            return;
          }

          const elapsed = event.elapsedSec.toFixed(1);
          const silenceOps = event.plan.operations.filter(
            (op) => op.type === "removeSilence",
          ).length;
          const retakeOpsCount = retakeOps(event.plan).length;

          console.log();
          console.log(chalk.bold("Done!"));
          console.log(`  ${chalk.dim("Input:")}    ${input}`);
          console.log(
            `  ${chalk.dim("Output:")}   ${chalk.cyan(event.output)}`,
          );
          console.log(
            `  ${chalk.dim("Silence:")}  ${silenceOps} region${silenceOps !== 1 ? "s" : ""} cut`,
          );
          console.log(`  ${chalk.dim("Retakes:")}  ${retakeOpsCount} cut`);
          console.log(
            `  ${chalk.dim("Saved:")}    ${chalk.yellow(formatDuration(event.savedSec))} (${event.savedPercent.toFixed(1)}%)`,
          );
          console.log(`  ${chalk.dim("Time:")}     ${elapsed}s`);
          console.log();
          return;
        }
        case "error": {
          if (currentSpinner) {
            currentSpinner.fail(event.message);
            currentSpinner = null;
            currentSpinnerStage = null;
          } else {
            console.error(chalk.red(event.message));
          }
          errored = true;
          exitCode = 1;
          return;
        }
      }
    }
  });
