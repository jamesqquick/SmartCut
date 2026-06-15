import { describe, expect, it } from "vitest";
import { mergeSubwordTokens } from "../llm/detect-retakes-llm.js";
import type { Token } from "../types.js";

function tok(
  word: string,
  start: number,
  end: number,
  leadingSpace: boolean,
): Token {
  return {
    word,
    normalized: word.toLowerCase().replace(/[^a-z0-9']/g, ""),
    start,
    end,
    isFiller: false,
    leadingSpace,
  };
}

describe("mergeSubwordTokens", () => {
  it("merges a mid-word continuation fragment into the preceding token", () => {
    // "rollbacks" => "roll" + "backs"
    const merged = mergeSubwordTokens([
      tok("roll", 1.0, 1.4, true),
      tok("backs", 1.4, 1.8, false),
    ]);
    expect(merged).toHaveLength(1);
    expect(merged[0].word).toBe("rollbacks");
    expect(merged[0].normalized).toBe("rollbacks");
    expect(merged[0].start).toBe(1.0);
    expect(merged[0].end).toBe(1.8);
  });

  it("merges a contraction tail (no leading space) into the head", () => {
    // "I'm" => "I" + "'m"
    const merged = mergeSubwordTokens([
      tok("I", 2.0, 2.2, true),
      tok("'m", 2.2, 2.3, false),
    ]);
    expect(merged).toHaveLength(1);
    expect(merged[0].word).toBe("I'm");
    expect(merged[0].end).toBe(2.3);
  });

  it("does not merge tokens that each begin a new word", () => {
    const tokens = [
      tok("open", 0, 0.5, true),
      tok("the", 0.5, 0.7, true),
      tok("terminal", 0.7, 1.2, true),
    ];
    const merged = mergeSubwordTokens(tokens);
    expect(merged.map((t) => t.word)).toEqual(["open", "the", "terminal"]);
  });

  it("keeps a leading continuation fragment as-is when there is no head", () => {
    const merged = mergeSubwordTokens([tok("backs", 0, 0.4, false)]);
    expect(merged).toHaveLength(1);
    expect(merged[0].word).toBe("backs");
  });

  it("treats undefined leadingSpace as a new word (no accidental merge)", () => {
    const a: Token = { ...tok("foo", 0, 1, true) };
    const b: Token = { ...tok("bar", 1, 2, true) };
    delete a.leadingSpace;
    delete b.leadingSpace;
    const merged = mergeSubwordTokens([a, b]);
    expect(merged.map((t) => t.word)).toEqual(["foo", "bar"]);
  });
});
