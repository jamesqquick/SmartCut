import type Anthropic from "@anthropic-ai/sdk";
import chalk from "chalk";
import { detectRetakesLLM } from "../llm/detect-retakes-llm.js";
import { snapRetakeCutRegion } from "../retake/snap.js";
import type { Token, Segment } from "../types.js";
import type { RemoveRetakeOp } from "../edit-plan.js";

function midpointInAnyCut(token: Token, cuts: Segment[]): boolean {
  const mid = (token.start + token.end) / 2;
  return cuts.some((c) => mid >= c.start && mid < c.end);
}

function overlapsAny(region: Segment, cuts: Segment[]): boolean {
  return cuts.some((c) => region.start < c.end && c.start < region.end);
}

/**
 * Detect retakes via the LLM, snap each cut region to nearby silence
 * boundaries, and convert to `removeRetake` EditPlan operations.
 *
 * Runs detection iteratively (up to `passes` times). Each pass re-runs the LLM
 * over only the words that survived the previous passes. This makes dense,
 * messy regions self-correcting: when one pass keeps an intermediate attempt
 * that still contains a repeat (the model can mis-judge a region with 4–5
 * restarts), the next pass — now looking at much cleaner text — catches the
 * leftover. The ratio/density guards inside detectRetakesLLM prevent a later
 * pass from cutting across an earlier pass's gap.
 *
 * @param client - Anthropic client (AI Gateway)
 * @param model - model id
 * @param tokens - word tokens from transcription
 * @param snapSilences - fine-grained silence segments for boundary snapping
 * @param maxRetakeRatio - drop cuts whose delete/keep word ratio exceeds this
 * @param passes - max detection passes (default 2); pass N runs on words kept after N-1
 */
export async function planLlmRetakeOps(
  client: Anthropic,
  model: string,
  tokens: Token[],
  snapSilences: Segment[],
  maxRetakeRatio?: number,
  passes: number = 2
): Promise<RemoveRetakeOp[]> {
  const allOps: RemoveRetakeOp[] = [];
  const cutRegions: Segment[] = [];
  let working = tokens;
  let passesRun = 0;

  for (let pass = 0; pass < Math.max(1, passes); pass++) {
    if (working.length === 0) break;

    passesRun++;
    const retakes = await detectRetakesLLM(
      client,
      model,
      working,
      maxRetakeRatio
    );
    if (retakes.length === 0) break;

    for (const r of retakes) {
      const snapped = snapRetakeCutRegion(r.cutRegion, snapSilences);
      // Skip a cut that overlaps one already made (a later pass can re-detect a
      // region the midpoint filter didn't fully clear at the boundaries).
      if (overlapsAny(snapped, cutRegions)) continue;
      allOps.push({
        type: "removeRetake",
        start: snapped.start,
        end: snapped.end,
        reason: r.reason,
        removedText: r.removedText,
        keptText: r.keptText,
        contextBefore: r.contextBefore,
        contextAfter: r.contextAfter,
        confidence: r.confidence,
      });
      cutRegions.push({ start: snapped.start, end: snapped.end });
    }

    if (pass + 1 < Math.max(1, passes)) {
      // Drop the words just removed; the next pass re-examines the cleaner rest.
      const before = working.length;
      working = working.filter((t) => !midpointInAnyCut(t, cutRegions));
      if (working.length === before) break; // nothing new removed → converged
    }
  }

  if (passesRun > 1) {
    console.log(
      chalk.dim(
        `Retake detection ran ${passesRun} passes; ${allOps.length} total cut(s).`
      )
    );
  }

  return allOps.sort((a, b) => a.start - b.start);
}
