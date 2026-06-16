import * as readline from "node:readline";
import {
  type PipelineEvent,
  type RetakeDecision,
  type RetakeReviewResult,
  type ReviewCutDecision,
  runSmartcut,
  type SmartcutConfig,
} from "quietcut-core";
import {
  extractClip,
  extractEditedPreview,
  extractStitchedClip,
  type EditedPreviewOptions,
} from "./audio-preview.js";
import type { Segment } from "quietcut-core";
import { getMetadata } from "./metadata.js";
import {
  parseRpcLine,
  RPC_ERROR,
  RpcDispatchError,
  RpcDispatcher,
  type RpcNotification,
  type RpcResponse,
} from "./rpc.js";

/** Anything the generator can be resumed with: a per-cut decision or a batch result. */
type JobDecision = RetakeDecision | RetakeReviewResult;

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

// -----------------------------------------------------------------------------
// Wire layer: write only protocol messages to stdout, everything else to stderr.
// -----------------------------------------------------------------------------

function logInfo(msg: string): void {
  process.stderr.write(`[quietcut-server] ${msg}\n`);
}

function logError(err: unknown): void {
  const msg = err instanceof Error ? (err.stack ?? err.message) : String(err);
  process.stderr.write(`[quietcut-server] ERROR: ${msg}\n`);
}

function send(message: RpcResponse | RpcNotification): void {
  process.stdout.write(`${JSON.stringify(message)}\n`);
}

function sendEvent(event: PipelineEvent): void {
  send({ jsonrpc: "2.0", method: "event", params: event });
}

// -----------------------------------------------------------------------------
// Job state: at most one smartcut job runs at a time.
// -----------------------------------------------------------------------------

type JobState = {
  decisions: AsyncQueue<JobDecision>;
  cancelRequested: boolean;
  /** Resolves once the generator returns. */
  finished: Promise<void>;
};

let activeJob: JobState | null = null;

class AsyncQueue<T> {
  private readonly items: T[] = [];
  private readonly waiters: Array<(value: T) => void> = [];

  push(item: T): void {
    const waiter = this.waiters.shift();
    if (waiter) waiter(item);
    else this.items.push(item);
  }

  async take(): Promise<T> {
    const head = this.items.shift();
    if (head !== undefined) return head;
    return new Promise<T>((resolve) => {
      this.waiters.push(resolve);
    });
  }
}

// -----------------------------------------------------------------------------
// Handlers.
// -----------------------------------------------------------------------------

type StartParams = {
  input: string;
  options: Partial<SmartcutConfig> & {
    output: string;
    whisperModel?: string;
  };
};

type DecideParams = {
  opId: string;
  action: "remove" | "keep" | "approveRest" | "cancel";
};

type SubmitReviewParams = {
  cuts: ReviewCutDecision[];
};

type ExtractClipParams = {
  path: string;
  startSec: number;
  endSec: number;
};

type ExtractStitchedClipParams = {
  path: string;
  removeStart: number;
  removeEnd: number;
  padSec?: number;
  tailSec?: number;
};

type ExtractEditedPreviewParams = {
  path: string;
  duration: number;
  focusStart: number;
  focusEnd: number;
  padSec?: number;
  tailSec?: number;
  leadInMs?: number;
  tailOutMs?: number;
  cuts?: Segment[];
  silences?: Segment[];
};

const dispatcher = new RpcDispatcher();

dispatcher.register("ping", async () => ({ pong: true }));

dispatcher.register("getMetadata", async (params) => {
  const p = params as { path?: string } | undefined;
  if (!p?.path) {
    throw new RpcDispatchError(RPC_ERROR.invalidParams, "missing params.path");
  }
  return await getMetadata(p.path);
});

dispatcher.register("extractClip", async (params) => {
  const p = params as ExtractClipParams | undefined;
  if (
    !p?.path ||
    typeof p.startSec !== "number" ||
    typeof p.endSec !== "number"
  ) {
    throw new RpcDispatchError(
      RPC_ERROR.invalidParams,
      "extractClip requires { path, startSec, endSec }",
    );
  }
  return await extractClip(p.path, p.startSec, p.endSec);
});

dispatcher.register("extractStitchedClip", async (params) => {
  const p = params as ExtractStitchedClipParams | undefined;
  if (
    !p?.path ||
    typeof p.removeStart !== "number" ||
    typeof p.removeEnd !== "number"
  ) {
    throw new RpcDispatchError(
      RPC_ERROR.invalidParams,
      "extractStitchedClip requires { path, removeStart, removeEnd }",
    );
  }
  return await extractStitchedClip(p.path, p.removeStart, p.removeEnd, {
    padSec: p.padSec,
    tailSec: p.tailSec,
  });
});

dispatcher.register("extractEditedPreview", async (params) => {
  const p = params as ExtractEditedPreviewParams | undefined;
  if (
    !p?.path ||
    typeof p.duration !== "number" ||
    typeof p.focusStart !== "number" ||
    typeof p.focusEnd !== "number"
  ) {
    throw new RpcDispatchError(
      RPC_ERROR.invalidParams,
      "extractEditedPreview requires { path, duration, focusStart, focusEnd }",
    );
  }
  const opts: EditedPreviewOptions = {
    padSec: p.padSec,
    tailSec: p.tailSec,
    leadInMs: p.leadInMs,
    tailOutMs: p.tailOutMs,
    cuts: p.cuts,
    silences: p.silences,
  };
  return await extractEditedPreview(
    p.path,
    p.duration,
    p.focusStart,
    p.focusEnd,
    opts,
  );
});

dispatcher.register("start", async (params) => {
  if (activeJob) {
    throw new RpcDispatchError(
      RPC_ERROR.jobAlreadyRunning,
      "A smartcut job is already running. Send `cancel` first.",
    );
  }

  const p = params as StartParams | undefined;
  if (!p?.input || !p.options?.output) {
    throw new RpcDispatchError(
      RPC_ERROR.invalidParams,
      "start requires { input, options.output }",
    );
  }

  const config = buildConfig(p.input, p.options);
  const whisperModel = p.options.whisperModel ?? "base.en";

  activeJob = startJob(config, whisperModel);

  // Resolve `start` immediately; events flow as notifications.
  return { jobId: "current" };
});

dispatcher.register("decide", async (params) => {
  if (!activeJob) {
    throw new RpcDispatchError(
      RPC_ERROR.jobNotRunning,
      "No smartcut job is running",
    );
  }
  const p = params as DecideParams | undefined;
  if (!p?.opId || !p.action) {
    throw new RpcDispatchError(
      RPC_ERROR.invalidParams,
      "decide requires { opId, action }",
    );
  }

  activeJob.decisions.push(mapAction(p.action));
  return { ok: true };
});

dispatcher.register("submitReview", async (params) => {
  if (!activeJob) {
    throw new RpcDispatchError(
      RPC_ERROR.jobNotRunning,
      "No smartcut job is running",
    );
  }
  const p = params as SubmitReviewParams | undefined;
  if (!p || !Array.isArray(p.cuts)) {
    throw new RpcDispatchError(
      RPC_ERROR.invalidParams,
      "submitReview requires { cuts: [...] }",
    );
  }

  activeJob.decisions.push({ kind: "review", cuts: p.cuts });
  return { ok: true };
});

dispatcher.register("cancel", async () => {
  if (!activeJob) return { ok: true, wasRunning: false };
  activeJob.cancelRequested = true;
  activeJob.decisions.push({ kind: "cancel" });
  return { ok: true, wasRunning: true };
});

function mapAction(action: DecideParams["action"]): RetakeDecision {
  switch (action) {
    case "remove":
      return { kind: "remove" };
    case "keep":
      return { kind: "keep" };
    case "approveRest":
      return { kind: "approveRest" };
    case "cancel":
      return { kind: "cancel" };
  }
}

function buildConfig(
  input: string,
  options: StartParams["options"],
): SmartcutConfig {
  return {
    input,
    output: options.output,
    thresholdDb: options.thresholdDb ?? -30,
    minSilence: options.minSilence ?? 0.6,
    model: options.model ?? "claude-opus-4-8",
    fillerWords: options.fillerWords ?? DEFAULT_FILLER_WORDS,
    maxRetakeRatio: options.maxRetakeRatio ?? 15,
    passes: options.passes ?? 2,
    transcriptPath: options.transcriptPath,
    saveTranscriptPath: options.saveTranscriptPath,
    planPath: options.planPath,
    savePlanPath: options.savePlanPath,
    // The app uses the batch transcript-review flow (single reviewReady event).
    batchReview: true,
    leadInMs: options.leadInMs ?? 300,
    tailOutMs: options.tailOutMs ?? 300,
    skipApproval: options.skipApproval ?? false,
    dryRun: options.dryRun ?? false,
    crf: options.crf ?? 18,
    preset: options.preset ?? "medium",
  };
}

// -----------------------------------------------------------------------------
// Job runner.
// -----------------------------------------------------------------------------

function startJob(config: SmartcutConfig, whisperModel: string): JobState {
  const decisions = new AsyncQueue<JobDecision>();
  const state: JobState = {
    decisions,
    cancelRequested: false,
    finished: Promise.resolve(),
  };

  state.finished = (async () => {
    const gen = runSmartcut(config, whisperModel);
    let nextDecision: JobDecision | undefined;

    try {
      while (true) {
        const { value, done } = await gen.next(nextDecision);
        nextDecision = undefined;
        if (done) break;

        sendEvent(value);

        // If the generator is waiting on a decision, block until the client
        // sends one. `retakeProposed` awaits a per-cut `decide`; `reviewReady`
        // (batch flow) awaits `submitReview` (or `cancel` for either).
        if (value.type === "retakeProposed" || value.type === "reviewReady") {
          if (state.cancelRequested) {
            nextDecision = { kind: "cancel" };
          } else {
            nextDecision = await decisions.take();
          }
        }
      }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      sendEvent({ type: "error", message });
      logError(err);
    } finally {
      if (state === activeJob) activeJob = null;
    }
  })();

  return state;
}

// -----------------------------------------------------------------------------
// Stdio loop.
// -----------------------------------------------------------------------------

const inFlight = new Set<Promise<unknown>>();

async function handleLine(line: string): Promise<void> {
  const parsed = parseRpcLine(line);
  if (!parsed) return;
  if (parsed.kind === "error") {
    send(parsed.response);
    return;
  }
  const response = await dispatcher.dispatch(parsed.request);
  send(response);
}

function trackInFlight(p: Promise<unknown>): void {
  inFlight.add(p);
  p.finally(() => inFlight.delete(p));
}

async function drainInFlight(): Promise<void> {
  while (inFlight.size > 0) {
    await Promise.allSettled([...inFlight]);
  }
  if (activeJob) {
    await activeJob.finished.catch(() => undefined);
  }
}

function main(): void {
  process.on("uncaughtException", (err) => logError(err));
  process.on("unhandledRejection", (err) => logError(err));

  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      logInfo(`received ${signal}, shutting down`);
      if (activeJob) {
        activeJob.cancelRequested = true;
        activeJob.decisions.push({ kind: "cancel" });
      }
      drainInFlight().finally(() => process.exit(0));
    });
  }

  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });
  rl.on("line", (line) => {
    trackInFlight(handleLine(line).catch((err) => logError(err)));
  });
  rl.on("close", () => {
    logInfo("stdin closed, draining and exiting");
    drainInFlight().finally(() => process.exit(0));
  });

  logInfo("ready");
}

main();
