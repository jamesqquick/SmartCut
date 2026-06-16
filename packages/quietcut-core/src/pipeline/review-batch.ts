import type { RemoveRetakeOp } from "../edit-plan.js";
import {
  reconstructText,
  sentenceAfter,
  sentenceBefore,
} from "../retake/transcript-text.js";
import type { Token, TranscriptToken } from "../types.js";
import type { ReviewCutDecision } from "./decisions.js";
import type { ReviewProposal } from "./events.js";

/**
 * opId prefix for user-created manual cuts. The Swift app stamps the same
 * prefix (`m-0`, `m-1`, …) when it creates a cut from a transcript selection;
 * AI proposals use `r-` (see {@link buildReviewProposals}). The prefix is the
 * only signal that tells {@link applyReviewResult} a proposal-less decision is
 * a manual cut rather than a stale id, so the two sides must agree on it.
 */
export const MANUAL_OP_PREFIX = "m-";

/**
 * Project a token to its midpoint time. Matches the midpoint test used by the
 * planner so a snapped cut maps to the same words it removes.
 */
function midpoint(token: Token): number {
  return (token.start + token.end) / 2;
}

/**
 * Map a cut's time range [start, end) to the inclusive token index range whose
 * midpoints fall inside it. Falls back to the token nearest the cut start when
 * the range contains no token midpoint (a cut sitting entirely in silence).
 */
export function timeRangeToIndices(
  tokens: Token[],
  start: number,
  end: number,
): { removeStartIndex: number; removeEndIndex: number } {
  let first = -1;
  let last = -1;
  for (let i = 0; i < tokens.length; i++) {
    const mid = midpoint(tokens[i]);
    if (mid >= start && mid < end) {
      if (first === -1) first = i;
      last = i;
    }
  }

  if (first !== -1) {
    return { removeStartIndex: first, removeEndIndex: last };
  }

  // Fallback: nearest token to the cut start (degenerate, near-empty cut).
  let nearest = 0;
  let bestDist = Infinity;
  for (let i = 0; i < tokens.length; i++) {
    const dist = Math.abs(midpoint(tokens[i]) - start);
    if (dist < bestDist) {
      bestDist = dist;
      nearest = i;
    }
  }
  return { removeStartIndex: nearest, removeEndIndex: nearest };
}

/**
 * Build the review proposals shown in the batch review screen: each retake op
 * paired with the inclusive token index range it currently removes.
 *
 * `opId` is `r-{i}` where i is the op's index in the (chronologically sorted)
 * retake list — the same scheme the per-cut CLI flow uses.
 */
export function buildReviewProposals(
  tokens: Token[],
  ops: RemoveRetakeOp[],
): ReviewProposal[] {
  return ops.map((op, i) => {
    const { removeStartIndex, removeEndIndex } = timeRangeToIndices(
      tokens,
      op.start,
      op.end,
    );
    return { opId: `r-${i}`, op, removeStartIndex, removeEndIndex };
  });
}

/**
 * Trim a token array down to the wire-friendly `TranscriptToken` shape.
 */
export function toTranscriptTokens(tokens: Token[]): TranscriptToken[] {
  return tokens.map((t) => ({ word: t.word, start: t.start, end: t.end }));
}

/**
 * Clamp an inclusive token index range to the transcript and project it to
 * exact word-boundary times: the cut starts at the first removed word and ends
 * at the onset of the next kept word (or that word's end if it's the last
 * token). Shared by the AI-rebuild and manual-cut paths so they can't drift.
 */
function rangeBounds(
  tokens: Token[],
  removeStartIndex: number,
  removeEndIndex: number,
): { s: number; e: number; start: number; end: number } {
  const s = Math.max(0, Math.min(removeStartIndex, tokens.length - 1));
  const e = Math.max(s, Math.min(removeEndIndex, tokens.length - 1));
  const start = tokens[s].start;
  const end = tokens[e + 1]?.start ?? tokens[e].end;
  return { s, e, start, end };
}

/**
 * Rebuild a `RemoveRetakeOp` from a user-adjusted inclusive token range.
 *
 * Manual edits use exact word boundaries (no silence re-snap). Display text
 * (removed/kept/context) is regenerated from the new range; the AI's `reason`
 * and `confidence` are preserved (the user moved boundaries, not the
 * rationale). Returns null for a degenerate (non-positive span) range.
 */
function rebuildOpFromRange(
  tokens: Token[],
  baseOp: RemoveRetakeOp,
  removeStartIndex: number,
  removeEndIndex: number,
): RemoveRetakeOp | null {
  const { s, e, start, end } = rangeBounds(
    tokens,
    removeStartIndex,
    removeEndIndex,
  );
  if (end <= start) return null;

  return {
    type: "removeRetake",
    start,
    end,
    reason: baseOp.reason,
    removedText: reconstructText(tokens, s, e),
    keptText: sentenceAfter(tokens, e + 1),
    contextBefore: sentenceBefore(tokens, s - 1),
    contextAfter: baseOp.contextAfter,
    confidence: baseOp.confidence,
  };
}

/**
 * Build a `RemoveRetakeOp` for a user-created manual cut from an inclusive token
 * range. Unlike {@link rebuildOpFromRange} there's no AI proposal behind it, so
 * the rationale is synthesized (`reason: "Manual cut"`, full confidence) and all
 * display text is generated from the transcript. Returns null for a degenerate
 * (non-positive span) range.
 */
export function buildManualOp(
  tokens: Token[],
  removeStartIndex: number,
  removeEndIndex: number,
): RemoveRetakeOp | null {
  const { s, e, start, end } = rangeBounds(
    tokens,
    removeStartIndex,
    removeEndIndex,
  );
  if (end <= start) return null;

  return {
    type: "removeRetake",
    start,
    end,
    reason: "Manual cut",
    removedText: reconstructText(tokens, s, e),
    keptText: sentenceAfter(tokens, e + 1),
    contextBefore: sentenceBefore(tokens, s - 1),
    contextAfter: sentenceAfter(tokens, e + 1),
    confidence: 100,
  };
}

/**
 * Apply the batch review result to the original proposals, producing the final
 * set of retake ops to keep.
 *
 * - Disabled cuts are dropped.
 * - An enabled cut whose range is unchanged keeps the original (pre-snapped) op
 *   so untouched AI suggestions retain their clean silence-aligned boundaries.
 * - An enabled cut whose range changed is rebuilt from exact word boundaries.
 * - An enabled cut with no matching proposal is a user-created manual cut (its
 *   opId carries the `m-` prefix) and is built from its word range alone. A
 *   proposal-less decision *without* that prefix is stale/unknown and dropped.
 */
export function applyReviewResult(
  tokens: Token[],
  proposals: ReviewProposal[],
  cuts: ReviewCutDecision[],
): RemoveRetakeOp[] {
  const byId = new Map(proposals.map((p) => [p.opId, p]));
  const result: RemoveRetakeOp[] = [];

  for (const cut of cuts) {
    if (!cut.enabled) continue;
    const proposal = byId.get(cut.opId);
    if (!proposal) {
      // A manual cut (m- prefix) has no AI proposal; build it from the user's
      // word range. Any other proposal-less id is stale and ignored.
      if (cut.opId.startsWith(MANUAL_OP_PREFIX)) {
        const manual = buildManualOp(
          tokens,
          cut.removeStartIndex,
          cut.removeEndIndex,
        );
        if (manual) result.push(manual);
      }
      continue;
    }

    const unchanged =
      cut.removeStartIndex === proposal.removeStartIndex &&
      cut.removeEndIndex === proposal.removeEndIndex;

    if (unchanged) {
      result.push(proposal.op);
      continue;
    }

    const rebuilt = rebuildOpFromRange(
      tokens,
      proposal.op,
      cut.removeStartIndex,
      cut.removeEndIndex,
    );
    if (rebuilt) result.push(rebuilt);
  }

  return result.sort((a, b) => a.start - b.start);
}
