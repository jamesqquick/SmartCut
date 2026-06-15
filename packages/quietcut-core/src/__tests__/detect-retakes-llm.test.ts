import type Anthropic from "@anthropic-ai/sdk";
import { describe, expect, it } from "vitest";
import { detectRetakesLLM } from "../llm/detect-retakes-llm.js";
import type { Token } from "../types.js";

type Cut = {
  abandonedStartIndex: number;
  keepStartIndex: number;
  keepEndIndex: number;
  reason: string;
  confidence?: number;
};

/** Wrap a message object as the streaming helper our code uses. */
function asStream(message: unknown) {
  return { finalMessage: async () => message };
}

/** Build a fake Anthropic client that returns a single tool call. */
function fakeClient(cuts: Cut[]): Anthropic {
  return {
    messages: {
      stream: () =>
        asStream({
          content: [
            { type: "tool_use", name: "report_retakes", input: { cuts } },
          ],
        }),
    },
  } as unknown as Anthropic;
}

/** A client that answers in text only (never calls the tool). */
function textOnlyClient(): Anthropic {
  return {
    messages: {
      stream: () =>
        asStream({
          content: [
            { type: "text", text: "There are no retakes in this transcript." },
          ],
        }),
    },
  } as unknown as Anthropic;
}

function tok(word: string, start: number, end: number): Token {
  return {
    word,
    normalized: word.toLowerCase().replace(/[^a-z0-9']/g, ""),
    start,
    end,
    isFiller: false,
    leadingSpace: true,
  };
}

describe("detectRetakesLLM", () => {
  it("returns [] for empty input without calling the model", async () => {
    const result = await detectRetakesLLM(fakeClient([]), "m", []);
    expect(result).toEqual([]);
  });

  it("treats a no-tool-call response as zero retakes (no error)", async () => {
    const tokens = [tok("hello", 0, 0.3), tok("world", 0.4, 0.7)];
    const result = await detectRetakesLLM(textOnlyClient(), "m", tokens);
    expect(result).toEqual([]);
  });

  it("extends a late-anchored abandoned start back across an exact prefix repeat", async () => {
    // "So first I going to [pause] so first I going to talk about"
    const tokens = [
      tok("So", 0.0, 0.2),
      tok("first", 0.3, 0.6),
      tok("I", 0.7, 0.8),
      tok("going", 0.9, 1.2),
      tok("to", 1.3, 1.5),
      tok("so", 2.0, 2.2),
      tok("first", 2.3, 2.6),
      tok("I", 2.7, 2.8),
      tok("going", 2.9, 3.2),
      tok("to", 3.3, 3.5),
      tok("talk", 3.6, 3.9),
      tok("about", 4.0, 4.3),
    ];
    // Model anchors the abandoned start one word late (at "first", index 1).
    const client = fakeClient([
      {
        abandonedStartIndex: 1,
        keepStartIndex: 5,
        keepEndIndex: 11,
        reason: "restart",
      },
    ]);

    const result = await detectRetakesLLM(client, "m", tokens);
    expect(result).toHaveLength(1);
    // refineAbandonedStart pulls the cut back to the very first "So" (index 0).
    expect(result[0].cutRegion.start).toBeCloseTo(0.0, 5);
    expect(result[0].cutRegion.end).toBeCloseTo(2.0, 5);
    expect(result[0].removedText).toBe("So first I going to");
    expect(result[0].keptText).toBe("so first I going to talk about");
  });

  it("drops a cut whose delete-to-keep ratio exceeds the guard", async () => {
    // 20 distinct words deleted to keep a single word -> ratio 20:1. That's not
    // a re-recording; it's a mis-pairing / looping transcript.
    const tokens = Array.from({ length: 21 }, (_, i) =>
      tok(`w${i}`, i, i + 0.5),
    );
    const client = fakeClient([
      {
        abandonedStartIndex: 0,
        keepStartIndex: 20,
        keepEndIndex: 20,
        reason: "x",
        confidence: 90,
      },
    ]);
    // Default ratio guard (15) drops it...
    expect(await detectRetakesLLM(client, "m", tokens)).toEqual([]);
    // ...but a high enough --max-retake-ratio keeps it (with tempered confidence).
    const kept = await detectRetakesLLM(client, "m", tokens, 100);
    expect(kept).toHaveLength(1);
    expect(kept[0].cutRegion).toEqual({ start: 0, end: 20 });
    // ratio 20 -> confidence capped at 30 even though the model reported 90.
    expect(kept[0].confidence).toBe(30);
  });

  it("drops a long cut with almost no words (untranscribed region, not a retake)", async () => {
    // "Thank you Thank you" spanning ~57s: whisper produced almost nothing here.
    // Token ratio looks fine, but word density is ~0.03 w/s — not a retake.
    const tokens = [
      tok("Thank", 632.0, 632.3),
      tok("you", 632.4, 632.7),
      tok("Thank", 660.0, 660.3),
      tok("you", 660.4, 660.7),
      tok("Now", 689.0, 689.3),
      tok("let's", 689.4, 689.7),
      tok("continue", 689.8, 690.3),
    ];
    const client = fakeClient([
      {
        abandonedStartIndex: 0,
        keepStartIndex: 4,
        keepEndIndex: 6,
        reason: "x",
        confidence: 85,
      },
    ]);
    expect(await detectRetakesLLM(client, "m", tokens)).toEqual([]);
  });

  it("passes through model confidence for a clean 1:1 retake", async () => {
    const tokens = [
      tok("hello", 0, 0.3),
      tok("world", 0.4, 0.7),
      tok("hello", 1.0, 1.3),
      tok("world", 1.4, 1.7),
    ];
    const client = fakeClient([
      {
        abandonedStartIndex: 0,
        keepStartIndex: 2,
        keepEndIndex: 3,
        reason: "restart",
        confidence: 88,
      },
    ]);
    const result = await detectRetakesLLM(client, "m", tokens);
    expect(result).toHaveLength(1);
    expect(result[0].confidence).toBe(88); // ratio ~1 -> cap 100, model wins
  });

  it("drops a cut whose kept-onset timestamp precedes the abandoned start (jitter guard)", async () => {
    const tokens = [tok("A", 5.0, 5.2), tok("B", 5.3, 5.6), tok("C", 4.0, 4.3)];
    const client = fakeClient([
      {
        abandonedStartIndex: 0,
        keepStartIndex: 2,
        keepEndIndex: 2,
        reason: "x",
      },
    ]);
    const result = await detectRetakesLLM(client, "m", tokens);
    expect(result).toEqual([]);
  });

  it("merges sub-word tokens before indexing so reconstructed text reads as words", async () => {
    // Raw whisper pieces: "roll"+"backs" (idx 0 after merge) and "undo"+"ing".
    const raw: Token[] = [
      { ...tok("roll", 0.0, 0.4) },
      { ...tok("backs", 0.4, 0.8), leadingSpace: false },
      { ...tok("are", 0.9, 1.1) },
      { ...tok("hard", 1.2, 1.5) },
      { ...tok("roll", 2.0, 2.4) },
      { ...tok("backs", 2.4, 2.8), leadingSpace: false },
      { ...tok("are", 2.9, 3.1) },
      { ...tok("tricky", 3.2, 3.6) },
    ];
    // After merge the indices are: [0]rollbacks [1]are [2]hard [3]rollbacks
    // [4]are [5]tricky. Abandoned take = 0..2, kept take = 3..5.
    const client = fakeClient([
      {
        abandonedStartIndex: 0,
        keepStartIndex: 3,
        keepEndIndex: 5,
        reason: "restart",
      },
    ]);
    const result = await detectRetakesLLM(client, "m", raw);
    expect(result).toHaveLength(1);
    expect(result[0].removedText).toBe("rollbacks are hard");
    expect(result[0].keptText).toBe("rollbacks are tricky");
  });
});
