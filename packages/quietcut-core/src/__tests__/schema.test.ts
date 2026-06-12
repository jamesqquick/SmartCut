import { describe, it, expect } from "vitest";
import {
  retakeToolInputSchema,
  validateRetakeCuts,
  sanitizeRetakeCuts,
  RetakeValidationError,
} from "../llm/schema.js";

describe("retakeToolInputSchema", () => {
  it("accepts well-formed tool input", () => {
    const parsed = retakeToolInputSchema.safeParse({
      cuts: [
        {
          abandonedStartIndex: 0,
          keepStartIndex: 3,
          keepEndIndex: 6,
          reason: "restart",
        },
      ],
    });
    expect(parsed.success).toBe(true);
  });

  it("rejects non-integer indices", () => {
    const parsed = retakeToolInputSchema.safeParse({
      cuts: [
        { abandonedStartIndex: 0.5, keepStartIndex: 3, keepEndIndex: 6, reason: "x" },
      ],
    });
    expect(parsed.success).toBe(false);
  });

  it("rejects an empty reason", () => {
    const parsed = retakeToolInputSchema.safeParse({
      cuts: [
        { abandonedStartIndex: 0, keepStartIndex: 3, keepEndIndex: 6, reason: "" },
      ],
    });
    expect(parsed.success).toBe(false);
  });
});

describe("validateRetakeCuts", () => {
  const ok = { abandonedStartIndex: 0, keepStartIndex: 3, keepEndIndex: 6, reason: "r" };

  it("returns the cuts when all invariants hold", () => {
    expect(validateRetakeCuts({ cuts: [ok] }, 10)).toEqual([ok]);
  });

  it("throws when an index is out of range", () => {
    expect(() => validateRetakeCuts({ cuts: [ok] }, 5)).toThrow(
      RetakeValidationError
    );
    expect(() => validateRetakeCuts({ cuts: [ok] }, 5)).toThrow(/out of range/);
  });

  it("throws when abandonedStartIndex is not before keepStartIndex", () => {
    expect(() =>
      validateRetakeCuts(
        { cuts: [{ ...ok, abandonedStartIndex: 3, keepStartIndex: 3 }] },
        10
      )
    ).toThrow(/must be less than keepStartIndex/);
  });

  it("throws when keepStartIndex exceeds keepEndIndex", () => {
    expect(() =>
      validateRetakeCuts(
        { cuts: [{ ...ok, keepStartIndex: 6, keepEndIndex: 5 }] },
        10
      )
    ).toThrow(/must be <= keepEndIndex/);
  });

  it("throws when two cuts overlap", () => {
    const cuts = [
      { abandonedStartIndex: 0, keepStartIndex: 2, keepEndIndex: 5, reason: "a" },
      { abandonedStartIndex: 4, keepStartIndex: 7, keepEndIndex: 9, reason: "b" },
    ];
    expect(() => validateRetakeCuts({ cuts }, 20)).toThrow(/cuts overlap/);
  });

  it("accepts disjoint, ordered cuts", () => {
    const cuts = [
      { abandonedStartIndex: 0, keepStartIndex: 2, keepEndIndex: 5, reason: "a" },
      { abandonedStartIndex: 6, keepStartIndex: 8, keepEndIndex: 9, reason: "b" },
    ];
    expect(validateRetakeCuts({ cuts }, 20)).toHaveLength(2);
  });
});

describe("sanitizeRetakeCuts", () => {
  it("keeps valid cuts untouched", () => {
    const cuts = [
      { abandonedStartIndex: 0, keepStartIndex: 2, keepEndIndex: 5, reason: "a" },
      { abandonedStartIndex: 6, keepStartIndex: 8, keepEndIndex: 9, reason: "b" },
    ];
    const out = sanitizeRetakeCuts(cuts, 20);
    expect(out.cuts).toHaveLength(2);
    expect(out.dropped).toHaveLength(0);
  });

  it("clamps an off-by-one keepEndIndex (== tokenCount) into range", () => {
    // The exact failure from the 15-min clip family: index one past the end.
    const cuts = [
      { abandonedStartIndex: 3640, keepStartIndex: 3644, keepEndIndex: 3647, reason: "r" },
    ];
    const out = sanitizeRetakeCuts(cuts, 3647);
    expect(out.cuts).toHaveLength(1);
    expect(out.cuts[0].keepEndIndex).toBe(3646);
    expect(out.dropped).toHaveLength(0);
  });

  it("drops a cut whose keepStartIndex is out of range, keeping the rest", () => {
    const cuts = [
      { abandonedStartIndex: 0, keepStartIndex: 2, keepEndIndex: 5, reason: "ok" },
      { abandonedStartIndex: 10, keepStartIndex: 3647, keepEndIndex: 3648, reason: "bad" },
    ];
    const out = sanitizeRetakeCuts(cuts, 3647);
    expect(out.cuts).toHaveLength(1);
    expect(out.cuts[0].reason).toBe("ok");
    expect(out.dropped).toHaveLength(1);
    expect(out.dropped[0].reason).toMatch(/out of range/);
  });

  it("drops cuts with broken index ordering", () => {
    const cuts = [
      { abandonedStartIndex: 5, keepStartIndex: 3, keepEndIndex: 8, reason: "x" },
    ];
    const out = sanitizeRetakeCuts(cuts, 20);
    expect(out.cuts).toHaveLength(0);
    expect(out.dropped[0].reason).toMatch(/not before keepStartIndex/);
  });

  it("resolves overlaps greedily, keeping the earliest cut", () => {
    const cuts = [
      { abandonedStartIndex: 0, keepStartIndex: 2, keepEndIndex: 8, reason: "first" },
      { abandonedStartIndex: 4, keepStartIndex: 7, keepEndIndex: 10, reason: "overlap" },
      { abandonedStartIndex: 12, keepStartIndex: 14, keepEndIndex: 16, reason: "later" },
    ];
    const out = sanitizeRetakeCuts(cuts, 20);
    expect(out.cuts.map((c) => c.reason)).toEqual(["first", "later"]);
    expect(out.dropped).toHaveLength(1);
    expect(out.dropped[0].reason).toMatch(/overlaps previous cut/);
  });

  it("never throws on malformed input", () => {
    const cuts = [
      { abandonedStartIndex: -1, keepStartIndex: 99, keepEndIndex: 99, reason: "junk" },
    ];
    expect(() => sanitizeRetakeCuts(cuts, 10)).not.toThrow();
    expect(sanitizeRetakeCuts(cuts, 10).cuts).toHaveLength(0);
  });

  it("clamps confidence into 0–100 and defaults missing to 50", () => {
    const out = sanitizeRetakeCuts(
      [
        { abandonedStartIndex: 0, keepStartIndex: 2, keepEndIndex: 5, reason: "a", confidence: 150 },
        { abandonedStartIndex: 6, keepStartIndex: 8, keepEndIndex: 9, reason: "b" },
      ],
      20
    );
    expect(out.cuts[0].confidence).toBe(100);
    expect(out.cuts[1].confidence).toBe(50);
  });
});
