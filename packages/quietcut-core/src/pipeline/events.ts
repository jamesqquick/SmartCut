import type { Segment } from "../types.js";
import type { EditPlan, RemoveRetakeOp } from "../edit-plan.js";

/**
 * Logical stages emitted by `runSmartcut`. Stage events carry a status
 * (`start` / `done` / `fail`) and optional human-readable detail.
 */
export type Stage =
  | "probe"
  | "extract-audio"
  | "silence-coarse"
  | "silence-fine"
  | "transcribe"
  | "detect-retakes"
  | "review"
  | "render";

/**
 * Discriminated union of every event the pipeline yields. Consumers
 * (CLI, sidecar, Swift app) switch on `type`.
 *
 * The wire format is intentionally serializable JSON — no Map, Set,
 * Function, or Date instances.
 */
export type PipelineEvent =
  | {
      type: "stage";
      stage: Stage;
      status: "start" | "done" | "fail";
      message?: string;
      durationMs?: number;
    }
  | {
      type: "progress";
      stage: Stage;
      current?: number;
      total?: number;
      percent?: number;
      note?: string;
    }
  | {
      type: "metadata";
      durationSec: number;
      sizeBytes: number;
      codec?: string;
      width?: number;
      height?: number;
    }
  | {
      type: "silenceFound";
      count: number;
      segments: Segment[];
    }
  | {
      type: "transcript";
      tokenCount: number;
      preview: string;
    }
  | {
      type: "retakeProposed";
      opId: string;
      op: RemoveRetakeOp;
      index: number;
      total: number;
    }
  | {
      type: "retakeDecision";
      opId: string;
      action: "remove" | "keep";
    }
  | {
      type: "renderProgress";
      frame?: number;
      fps?: number;
      speed?: number;
      percent?: number;
      etaSec?: number;
    }
  | {
      type: "done";
      plan: EditPlan;
      output: string;
      savedSec: number;
      savedPercent: number;
      elapsedSec: number;
    }
  | {
      type: "error";
      message: string;
      stage?: Stage;
      stack?: string;
    };
