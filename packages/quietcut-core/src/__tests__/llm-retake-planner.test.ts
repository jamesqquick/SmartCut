import { describe, it, expect } from "vitest";
import type Anthropic from "@anthropic-ai/sdk";
import { planLlmRetakeOps } from "../planners/llm-retake-planner.js";
import type { Token } from "../types.js";

type Cut = {
  abandonedStartIndex: number;
  keepStartIndex: number;
  keepEndIndex: number;
  reason: string;
  confidence?: number;
};

/** Fake client returning a queued tool response per call; tracks call count. */
function queuedClient(responses: Cut[][]): { client: Anthropic; calls: () => number } {
  let i = 0;
  const client = {
    messages: {
      stream: () => {
        const cuts = responses[Math.min(i, responses.length - 1)];
        i++;
        return {
          finalMessage: async () => ({
            content: [{ type: "tool_use", name: "report_retakes", input: { cuts } }],
          }),
        };
      },
    },
  } as unknown as Anthropic;
  return { client, calls: () => i };
}

function tok(word: string, start: number, end: number): Token {
  return { word, normalized: word.toLowerCase(), start, end, isFiller: false, leadingSpace: true };
}

const TOKENS: Token[] = [
  tok("hello", 0.0, 0.3),
  tok("world", 0.4, 0.7),
  tok("hello", 1.0, 1.3),
  tok("world", 1.4, 1.7),
  tok("then", 2.0, 2.3),
  tok("done", 2.4, 2.7),
];

describe("planLlmRetakeOps iteration", () => {
  it("stops after one pass when the first pass finds nothing", async () => {
    const { client, calls } = queuedClient([[]]);
    const ops = await planLlmRetakeOps(client, "m", TOKENS, [], 15, 2);
    expect(ops).toEqual([]);
    expect(calls()).toBe(1);
  });

  it("runs a second pass and keeps cuts from both", async () => {
    // Pass 1 cuts the leading "hello world" (0..1, keep 2..3). Pass 2 then runs
    // on the remaining words and finds nothing.
    const { client, calls } = queuedClient([
      [{ abandonedStartIndex: 0, keepStartIndex: 2, keepEndIndex: 3, reason: "dup", confidence: 90 }],
      [],
    ]);
    const ops = await planLlmRetakeOps(client, "m", TOKENS, [], 15, 2);
    expect(ops).toHaveLength(1);
    expect(ops[0].type).toBe("removeRetake");
    expect(calls()).toBe(2);
  });

  it("dedupes a pass-2 cut that overlaps a pass-1 cut", async () => {
    // Dense tokens so the density guard doesn't interfere. Pass 1 cuts a small
    // middle region; pass 2 (on the remaining tokens) returns a cut that spans
    // across that region, overlapping it. The planner must drop the overlap.
    const dense: Token[] = Array.from({ length: 8 }, (_, i) =>
      tok(`w${i}`, i * 0.3, i * 0.3 + 0.25)
    );
    const { client, calls } = queuedClient([
      [{ abandonedStartIndex: 3, keepStartIndex: 4, keepEndIndex: 5, reason: "p1", confidence: 90 }],
      [{ abandonedStartIndex: 2, keepStartIndex: 5, keepEndIndex: 6, reason: "p2-overlap", confidence: 90 }],
    ]);
    const ops = await planLlmRetakeOps(client, "m", dense, [], 15, 2);
    expect(calls()).toBe(2); // pass 2 did run
    expect(ops).toHaveLength(1); // its overlapping cut was dropped
  });

  it("honors passes=1 (single detection call)", async () => {
    const { client, calls } = queuedClient([
      [{ abandonedStartIndex: 0, keepStartIndex: 2, keepEndIndex: 3, reason: "dup", confidence: 90 }],
      [{ abandonedStartIndex: 0, keepStartIndex: 1, keepEndIndex: 2, reason: "more", confidence: 90 }],
    ]);
    const ops = await planLlmRetakeOps(client, "m", TOKENS, [], 15, 1);
    expect(ops).toHaveLength(1);
    expect(calls()).toBe(1);
  });
});
