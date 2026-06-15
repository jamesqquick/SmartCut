import { describe, expect, it } from "vitest";
import type { RemoveRetakeOp } from "../edit-plan.js";
import type { ReviewCutDecision } from "../pipeline/decisions.js";
import {
  applyReviewResult,
  buildReviewProposals,
  timeRangeToIndices,
  toTranscriptTokens,
} from "../pipeline/review-batch.js";
import type { Token } from "../types.js";

// Build a simple token per word, each 1s long, contiguous from t=0.
// "zero" -> [0,1), "one" -> [1,2), ...
function makeTokens(words: string[]): Token[] {
  return words.map((word, i) => ({
    word,
    normalized: word.toLowerCase().replace(/[^a-z0-9]/g, ""),
    start: i,
    end: i + 1,
    isFiller: false,
  }));
}

function retakeOp(start: number, end: number): RemoveRetakeOp {
  return {
    type: "removeRetake",
    start,
    end,
    reason: "stumble-restart",
    removedText: "orig removed",
    keptText: "orig kept",
    contextBefore: "orig before",
    contextAfter: "orig after",
    confidence: 88,
  };
}

const WORDS = [
  "So",
  "first",
  "we",
  "so",
  "first",
  "we",
  "open",
  "the",
  "file",
  "and",
  "save",
];
const tokens = makeTokens(WORDS);

describe("timeRangeToIndices", () => {
  it("maps a time range to the inclusive token indices it covers", () => {
    // Cut covering tokens 0..2 (midpoints 0.5, 1.5, 2.5).
    const r = timeRangeToIndices(tokens, 0, 3);
    expect(r).toEqual({ removeStartIndex: 0, removeEndIndex: 2 });
  });

  it("uses token midpoints (end is exclusive)", () => {
    // [3, 6) covers midpoints 3.5, 4.5, 5.5 → tokens 3,4,5.
    const r = timeRangeToIndices(tokens, 3, 6);
    expect(r).toEqual({ removeStartIndex: 3, removeEndIndex: 5 });
  });

  it("falls back to the nearest token when no midpoint is inside", () => {
    // A sliver near token 4's midpoint (4.5) but containing no midpoint.
    const r = timeRangeToIndices(tokens, 4.1, 4.4);
    expect(r.removeStartIndex).toBe(r.removeEndIndex);
    expect(r.removeStartIndex).toBe(4);
  });
});

describe("buildReviewProposals", () => {
  it("pairs each op with its token range and an r-{i} id", () => {
    const ops = [retakeOp(0, 3), retakeOp(6, 8)];
    const proposals = buildReviewProposals(tokens, ops);
    expect(proposals).toHaveLength(2);
    expect(proposals[0].opId).toBe("r-0");
    expect(proposals[0].removeStartIndex).toBe(0);
    expect(proposals[0].removeEndIndex).toBe(2);
    expect(proposals[1].opId).toBe("r-1");
    expect(proposals[1].removeStartIndex).toBe(6);
    expect(proposals[1].removeEndIndex).toBe(7);
  });
});

describe("toTranscriptTokens", () => {
  it("trims tokens to word + timing", () => {
    const trimmed = toTranscriptTokens(tokens.slice(0, 2));
    expect(trimmed).toEqual([
      { word: "So", start: 0, end: 1 },
      { word: "first", start: 1, end: 2 },
    ]);
  });
});

describe("applyReviewResult", () => {
  const ops = [retakeOp(0, 3)];
  const proposals = buildReviewProposals(tokens, ops); // r-0 → [0,2]

  it("preserves the original (snapped) op when the range is unchanged", () => {
    const cuts: ReviewCutDecision[] = [
      { opId: "r-0", enabled: true, removeStartIndex: 0, removeEndIndex: 2 },
    ];
    const result = applyReviewResult(tokens, proposals, cuts);
    expect(result).toHaveLength(1);
    // Identity-preserving: same object fields, including original display text.
    expect(result[0]).toEqual(ops[0]);
  });

  it("drops a disabled cut", () => {
    const cuts: ReviewCutDecision[] = [
      { opId: "r-0", enabled: false, removeStartIndex: 0, removeEndIndex: 2 },
    ];
    expect(applyReviewResult(tokens, proposals, cuts)).toEqual([]);
  });

  it("rebuilds from exact word boundaries when the user widens the range", () => {
    // Widen to remove tokens 0..5 (so first we so first we → keep "open ...").
    const cuts: ReviewCutDecision[] = [
      { opId: "r-0", enabled: true, removeStartIndex: 0, removeEndIndex: 5 },
    ];
    const result = applyReviewResult(tokens, proposals, cuts);
    expect(result).toHaveLength(1);
    const op = result[0];
    expect(op.start).toBe(0); // tokens[0].start
    expect(op.end).toBe(6); // tokens[6].start (onset of next kept word "open")
    expect(op.removedText).toBe("So first we so first we");
    expect(op.reason).toBe("stumble-restart"); // preserved from AI
    expect(op.confidence).toBe(88); // preserved from AI
  });

  it("rebuilds when the user narrows the range", () => {
    const cuts: ReviewCutDecision[] = [
      { opId: "r-0", enabled: true, removeStartIndex: 3, removeEndIndex: 5 },
    ];
    const result = applyReviewResult(tokens, proposals, cuts);
    expect(result[0].start).toBe(3);
    expect(result[0].end).toBe(6);
    expect(result[0].removedText).toBe("so first we");
  });

  it("sorts surviving cuts by start time", () => {
    const twoOps = [retakeOp(6, 8), retakeOp(0, 3)];
    const twoProps = buildReviewProposals(tokens, twoOps); // r-0 later, r-1 earlier
    const cuts: ReviewCutDecision[] = [
      { opId: "r-0", enabled: true, removeStartIndex: 6, removeEndIndex: 7 },
      { opId: "r-1", enabled: true, removeStartIndex: 0, removeEndIndex: 2 },
    ];
    const result = applyReviewResult(tokens, twoProps, cuts);
    expect(result.map((o) => o.start)).toEqual([0, 6]);
  });

  it("ignores unknown opIds", () => {
    const cuts: ReviewCutDecision[] = [
      { opId: "r-99", enabled: true, removeStartIndex: 0, removeEndIndex: 2 },
    ];
    expect(applyReviewResult(tokens, proposals, cuts)).toEqual([]);
  });
});
