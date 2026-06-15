import { readFile, writeFile } from "node:fs/promises";
import {
  applyPadding,
  invertToKeep,
  mergeOverlaps,
  subtractRegions,
} from "./segments.js";
import type { Segment } from "./types.js";

// ---------------------------------------------------------------------------
// EditPlan — the time-based spine of the editing pipeline.
//
// Every stage (silence, retake, and eventually overlays/b-roll/animations)
// contributes operations to a single EditPlan. One renderer consumes the plan
// and produces a single encode. v1 only emits the two subtractive `remove*`
// operations; the union of additive op types is intentionally left open.
// ---------------------------------------------------------------------------

export type RemoveSilenceOp = {
  type: "removeSilence";
  start: number; // seconds
  end: number; // seconds
};

export type RemoveRetakeOp = {
  type: "removeRetake";
  start: number; // seconds (snapped cut start)
  end: number; // seconds (snapped cut end)
  reason: string; // LLM rationale
  removedText: string; // reconstructed take being removed (display)
  keptText: string; // surviving take shown "in lieu of" (display)
  contextBefore: string; // sentence preceding the cut (display)
  contextAfter: string; // sentence following the kept take (display)
  confidence: number; // 0–100, model-reported and tempered by delete/keep ratio
};

export type EditOperation = RemoveSilenceOp | RemoveRetakeOp;

export type EditPlan = {
  source: string; // input file path
  duration: number; // seconds
  operations: EditOperation[];
};

const REMOVE_TYPES = new Set(["removeSilence", "removeRetake"]);

/**
 * Assemble an EditPlan from the source metadata and its operations.
 * Operations are sorted by start time for stable previews/serialization.
 */
export function buildEditPlan(
  source: string,
  duration: number,
  operations: EditOperation[],
): EditPlan {
  const sorted = [...operations].sort((a, b) => a.start - b.start);
  return { source, duration, operations: sorted };
}

/**
 * Return only the retake operations, in chronological order.
 */
export function retakeOps(plan: EditPlan): RemoveRetakeOp[] {
  return plan.operations.filter(
    (op): op is RemoveRetakeOp => op.type === "removeRetake",
  );
}

/**
 * Collapse all subtractive (`remove*`) operations into the keep segments to
 * render, applying lead-in/tail-out padding and merging overlaps.
 */
export function planToKeepSegments(
  plan: EditPlan,
  leadInMs: number,
  tailOutMs: number,
): Segment[] {
  const cuts: Segment[] = plan.operations
    .filter((op) => op.type === "removeSilence" || op.type === "removeRetake")
    .map((op) => ({ start: op.start, end: op.end }));

  const mergedCuts = mergeOverlaps(cuts);
  const raw = invertToKeep(mergedCuts, plan.duration);
  const padded = mergeOverlaps(
    applyPadding(raw, leadInMs, tailOutMs, plan.duration),
  );

  // Padding adds breathing room around silence cuts, but it must never bleed
  // back into a retake cut (that would re-add removed speech, e.g. a repeated
  // "So first"). Clip retake regions back out after padding.
  const retakeRegions: Segment[] = plan.operations
    .filter((op) => op.type === "removeRetake")
    .map((op) => ({ start: op.start, end: op.end }));

  return subtractRegions(padded, retakeRegions);
}

/**
 * Serialize an EditPlan to a JSON file.
 */
export async function savePlan(path: string, plan: EditPlan): Promise<void> {
  await writeFile(path, JSON.stringify(plan, null, 2), "utf8");
}

/**
 * Load and minimally validate an EditPlan from a JSON file.
 */
export async function loadPlan(path: string): Promise<EditPlan> {
  const raw = await readFile(path, "utf8");
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new Error(`Plan file is not valid JSON: ${(err as Error).message}`);
  }

  if (
    typeof parsed !== "object" ||
    parsed === null ||
    typeof (parsed as EditPlan).source !== "string" ||
    typeof (parsed as EditPlan).duration !== "number" ||
    !Array.isArray((parsed as EditPlan).operations)
  ) {
    throw new Error(
      "Plan file is missing required fields (source, duration, operations).",
    );
  }

  const plan = parsed as EditPlan;

  if (!Number.isFinite(plan.duration) || plan.duration <= 0) {
    throw new Error(`Plan has an invalid duration: ${plan.duration}.`);
  }

  for (let i = 0; i < plan.operations.length; i++) {
    const op = plan.operations[i];
    if (!REMOVE_TYPES.has(op.type)) {
      throw new Error(
        `Plan contains unsupported operation type: "${op.type}".`,
      );
    }
    if (typeof op.start !== "number" || typeof op.end !== "number") {
      throw new Error("Plan operation is missing numeric start/end.");
    }
    if (!Number.isFinite(op.start) || !Number.isFinite(op.end)) {
      throw new Error(
        `Plan operation ${i} has a non-finite start/end (${op.start}, ${op.end}).`,
      );
    }
    if (op.start < 0 || op.end > plan.duration) {
      throw new Error(
        `Plan operation ${i} (${op.start}–${op.end}) falls outside the source duration (0–${plan.duration}).`,
      );
    }
    if (op.end <= op.start) {
      throw new Error(
        `Plan operation ${i} has a non-positive span (start ${op.start} >= end ${op.end}).`,
      );
    }
  }

  return plan;
}
