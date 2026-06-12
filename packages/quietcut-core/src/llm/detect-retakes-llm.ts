import type Anthropic from "@anthropic-ai/sdk";
import chalk from "chalk";
import type { Token, Segment } from "../types.js";
import { normalizeWord } from "../retake/transcribe.js";
import {
  retakeToolInputSchema,
  retakeToolJsonSchema,
  validateRetakeCuts,
  sanitizeRetakeCuts,
  RetakeValidationError,
  type RetakeCut,
} from "./schema.js";

// ---------------------------------------------------------------------------
// Contextual retake detection via Claude tool use.
// ---------------------------------------------------------------------------

const TOOL_NAME = "report_retakes";
// Generous budget: with adaptive thinking enabled, this covers thinking tokens
// plus the cuts JSON. The cuts payload itself is small (a few hundred tokens
// even for many cuts); the headroom is for the model's reasoning.
const MAX_OUTPUT_TOKENS = 32000;

// A real retake deletes roughly as much as it keeps (you said the line, then
// said it again — we delete the earlier attempt[s] and keep one). The ratio of
// deleted words to kept words stays low (≈1–3, a touch higher for 3–4 attempts).
// A wildly lopsided ratio means the model paired two distant occurrences of a
// recurring phrase, or the transcript looped (e.g. a whisper hallucination
// repeating one sentence hundreds of times) — delete-vs-keep in the hundreds.
// Cuts above this ratio are dropped outright; everything else flows to per-cut
// review (the human is the safety net). Overridable via the planner/command.
export const DEFAULT_MAX_RETAKE_RATIO = 15;

// A genuine retake's removed region is dense speech (the earlier attempt[s]).
// If a cut spans real time but contains almost no words, the transcript was
// sparse there — whisper failed to capture the audio (not actual silence, which
// the silence pass handles) — and deleting it would drop real, untranscribed
// content. Drop cuts longer than this many seconds whose word density is below
// MIN_RETAKE_WORD_DENSITY words/second.
const MIN_SPAN_FOR_DENSITY_CHECK = 5;
const MIN_RETAKE_WORD_DENSITY = 0.8;

/**
 * Map a delete/keep token ratio to a confidence ceiling. A genuine retake sits
 * near 1:1; as the ratio climbs the cut gets more suspicious, so we cap how
 * confident it can appear regardless of the model's self-report.
 */
function ratioConfidenceCap(ratio: number): number {
  if (ratio <= 2) return 100;
  if (ratio >= 12) return 30;
  // Linear from 100 (ratio 2) down to 30 (ratio 12).
  return Math.round(100 - ((ratio - 2) / (12 - 2)) * 70);
}

export type LlmRetake = {
  cutRegion: Segment; // unsnapped; planner snaps to silence
  reason: string;
  removedText: string;
  keptText: string;
  contextBefore: string; // sentence before the removed take
  contextAfter: string; // sentence after the kept take
  confidence: number; // 0–100, model-reported tempered by delete/keep ratio
};

const MAX_CONTEXT_WORDS = 6;
const SENTENCE_END = /[.!?]["')\]]?$/;

const SYSTEM_PROMPT = `You are a video editor's assistant. You are given a transcript of a single-speaker recording (a coding/tech tutorial) as a numbered list of word tokens. The speaker frequently re-records lines: they flub a sentence, pause, and say it again. Your job is to find every spot where the speaker re-recorded something and keep ONLY the latest (final) take.

For each retake, report:
- "abandonedStartIndex": the index of the FIRST word of the earlier attempt (the very first word of the first time they started saying it).
- "keepStartIndex": the index of the FIRST word of the final take you are keeping.
- "keepEndIndex": the index of the LAST word of that final take.
- "reason": a short explanation.
- "confidence": an integer 0–100 — how sure you are this is a genuine re-recorded retake. Use a high value (85–100) for a clear stumble-and-restart of the same line; a medium value (50–80) when the two attempts are paraphrased or you are unsure they are the same line; a low value (below 50) when it might be intentional/rhetorical repetition. Be honest — this is shown to a human for review.

How the cut works: EVERYTHING from abandonedStartIndex up to (but not including) keepStartIndex will be deleted. This must cover the entire earlier attempt PLUS any filler or false-starts between the two takes.

A retake is LOCAL and SHORT: the redo comes IMMEDIATELY after the flubbed attempt — they stumble, pause for a moment, and say the same line again right away. The abandoned attempt and the kept attempt are ADJACENT in the transcript, typically a handful of words apart and at most one or two sentences. The deleted span (abandonedStartIndex up to keepStartIndex) should be small.

Critical rules:
- NEVER pair two occurrences that are far apart in the transcript. If a similar phrase appears again many words/sentences later, that is the speaker naturally saying it again (a recurring action, a callback, a repeated step like "let's go to the next page", or returning to a topic) — it is NOT a retake. A retake's two attempts are back-to-back; if there is unrelated content spoken between them, it is not a retake.
- A single cut must not delete a large stretch of distinct content. If applying a cut would remove more than roughly one or two sentences of speech, you have almost certainly mis-paired a later occurrence with an earlier one — do not report it.
- After the deletion, the words just BEFORE abandonedStartIndex must flow directly into the kept take with NO repeated or duplicated phrases. Mentally read "[words before abandonedStartIndex] + [words from keepStartIndex to keepEndIndex]" and confirm nothing is said twice.
- Set abandonedStartIndex to the VERY FIRST word of the first attempt. Do not leave a duplicated leading word (e.g. if the transcript says "So first I'm going to so first I'm going to talk...", abandonedStartIndex is the first "So", and keepStartIndex is the second "so").
- The later take is always the keeper.
- Takes may NOT match word-for-word. Match by meaning/intent (paraphrases, partial restarts, and false starts all count) — but only when the two attempts are adjacent.
- For 3+ attempts of the same line in a row, set abandonedStartIndex at the FIRST attempt and keepStartIndex at the FINAL (cleanest) attempt, so ALL earlier attempts are deleted in one cut. Scan backward from the final take through EVERY immediately-preceding attempt — including messy ones where the speaker restarts, pivots to a slightly different phrasing, then restarts again — and anchor abandonedStartIndex at the very first of that run. Do not stop at just the most recent attempt.
- The kept take (keepStartIndex..keepEndIndex) must be ONE clean delivery with no internal repetition. Set keepEndIndex at the end of the first clean run-through. If the speaker then says (part of) it AGAIN after that, do NOT extend keepEndIndex over it — report a SEPARATE disjoint cut for that later repeat instead.
- Cuts must be disjoint: each abandonedStartIndex must come after the previous cut's keepEndIndex.
- Do NOT flag intentional or rhetorical repetition: e.g. "really, really important", repeating a command for emphasis, lists, callbacks, or a phrase/step that simply recurs later in the tutorial. Only flag content that was clearly RE-RECORDED back-to-back.
- If there are no retakes, return an empty "cuts" array.
- Use the report_retakes tool to return your answer. Token indices only — never timestamps.`;

/**
 * whisper.cpp emits sub-word pieces, not words: "rollbacks" comes back as
 * "roll"+"backs" and "I'm" as "I"+"'m". Pieces that begin a new word carry a
 * leading space (Token.leadingSpace === true); continuation pieces do not. This
 * folds each continuation piece into the preceding token so the LLM reasons
 * over whole words, token indices aren't inflated, and removed/kept/context
 * text reads cleanly ("rollbacks", not "roll backs"; "I'm", not "I 'm").
 *
 * The merged token spans the full word: start of the head piece to end of the
 * last piece. A leading continuation piece (no previous token to attach to) is
 * kept as-is.
 */
export function mergeSubwordTokens(tokens: Token[]): Token[] {
  const merged: Token[] = [];
  for (const t of tokens) {
    const isContinuation = t.leadingSpace === false && merged.length > 0;
    if (isContinuation) {
      const head = merged[merged.length - 1];
      const word = head.word + t.word;
      merged[merged.length - 1] = {
        ...head,
        word,
        normalized: normalizeWord(word),
        end: t.end,
      };
    } else {
      merged.push({ ...t });
    }
  }
  return merged;
}

function buildIndexedTranscript(tokens: Token[]): string {
  return tokens.map((t, i) => `[${i}] ${t.word}`).join(" ");
}

function reconstructText(tokens: Token[], start: number, end: number): string {
  return tokens
    .slice(start, end + 1)
    .map((t) => t.word)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * Collect the sentence ending at (and including) token `endIdx`, walking back
 * until the previous token ends a sentence or the word limit is reached.
 */
function sentenceBefore(tokens: Token[], endIdx: number): string {
  if (endIdx < 0) return "";
  let start = endIdx;
  let count = 0;
  while (start > 0 && count < MAX_CONTEXT_WORDS) {
    if (SENTENCE_END.test(tokens[start - 1].word)) break;
    start--;
    count++;
  }
  return reconstructText(tokens, start, endIdx);
}

/**
 * Collect the sentence starting at token `startIdx`, walking forward until a
 * sentence-ending token or the word limit is reached.
 */
function sentenceAfter(tokens: Token[], startIdx: number): string {
  if (startIdx >= tokens.length) return "";
  let end = startIdx;
  let count = 0;
  while (end < tokens.length && count < MAX_CONTEXT_WORDS) {
    if (SENTENCE_END.test(tokens[end].word)) break;
    end++;
    count++;
  }
  end = Math.min(end, tokens.length - 1);
  return reconstructText(tokens, startIdx, end);
}

/**
 * Models often anchor `abandonedStartIndex` a word or two too late, leaving the
 * leading word(s) of the repeated phrase duplicated in the output (e.g.
 * "So so first..."). A stutter-restart's abandoned take is a prefix-copy of the
 * kept take, so we can extend the deletion backward deterministically: find the
 * largest L where the L tokens immediately before keepStart exactly match the
 * first L tokens of the kept take, and start the cut there instead.
 *
 * Returns the earliest of the model's index and the computed start, so an exact
 * repeat is fully removed while paraphrased retakes (no exact prefix match) fall
 * back to the model's judgment.
 */
function refineAbandonedStart(
  tokens: Token[],
  modelStart: number,
  keepStart: number,
  keepEnd: number
): number {
  const maxL = Math.min(keepStart, keepEnd - keepStart + 1);
  let best = keepStart; // no extension found
  for (let L = maxL; L >= 1; L--) {
    let matches = true;
    for (let j = 0; j < L; j++) {
      if (tokens[keepStart - L + j].normalized !== tokens[keepStart + j].normalized) {
        matches = false;
        break;
      }
    }
    if (matches) {
      best = keepStart - L;
      break;
    }
  }
  return Math.max(0, Math.min(modelStart, best));
}

function extractToolInput(message: Anthropic.Message): unknown {
  for (const block of message.content) {
    if (block.type === "tool_use" && block.name === TOOL_NAME) {
      return block.input;
    }
  }
  return undefined;
}

/**
 * Run the model once and return the shape-parsed cuts (indices are guaranteed
 * to be non-negative integers, but NOT yet checked against the token count or
 * cross-cut invariants).
 *
 * Returns `null` when the model answered WITHOUT calling the tool — under
 * `tool_choice: auto` this happens occasionally (e.g. the model narrates "no
 * retakes"), and it should be treated as "no retakes", not a hard error.
 * Throws RetakeValidationError only when the tool WAS called but the payload is
 * structurally invalid (so the caller can issue a repair retry).
 */
async function requestRawCuts(
  client: Anthropic,
  model: string,
  messages: Anthropic.MessageParam[]
): Promise<RetakeCut[] | null> {
  // Adaptive thinking (Opus 4.8 / Sonnet 4.6) materially improves this
  // reasoning-heavy task, but it forbids forced tool_choice and a fixed
  // temperature. So we use tool_choice "auto" (the prompt still instructs the
  // model to always call report_retakes) and omit temperature. The `thinking`
  // and (optional) effort fields aren't typed by the installed SDK version, so
  // the params object is cast; the SDK forwards them in the request body.
  const params = {
    model,
    max_tokens: MAX_OUTPUT_TOKENS,
    thinking: { type: "adaptive" },
    system: SYSTEM_PROMPT,
    tools: [
      {
        name: TOOL_NAME,
        description:
          "Report every re-recorded take detected in the transcript so the earlier attempts can be cut.",
        input_schema: retakeToolJsonSchema as unknown as Anthropic.Tool.InputSchema,
      },
    ],
    tool_choice: { type: "auto" },
    messages,
  } as unknown as Anthropic.MessageCreateParamsStreaming;

  // Stream and assemble the final message. A large max_tokens with adaptive
  // thinking can exceed the SDK's 10-minute non-streaming limit, so streaming
  // is required (the gateway passes SSE through transparently).
  const message = await client.messages.stream(params).finalMessage();

  const rawInput = extractToolInput(message);
  if (rawInput === undefined) {
    return null; // model didn't call the tool → caller treats as "no retakes"
  }

  const parsed = retakeToolInputSchema.safeParse(rawInput);
  if (!parsed.success) {
    throw new RetakeValidationError(
      `Tool input failed schema validation: ${parsed.error.issues
        .map((i) => `${i.path.join(".")}: ${i.message}`)
        .join("; ")}`
    );
  }

  return parsed.data.cuts;
}

/**
 * Detect retakes contextually using Claude.
 *
 * Flow: request cuts, strictly validate against the token count to drive a
 * single repair retry, then ALWAYS run the lenient sanitizer as a final safety
 * net. Sanitizing (rather than throwing on the last attempt) means a single
 * malformed cut — e.g. an off-by-one index in a long transcript — drops just
 * that cut instead of aborting the whole job. Surviving cuts are mapped from
 * token index ranges to time.
 */
export async function detectRetakesLLM(
  client: Anthropic,
  model: string,
  rawTokens: Token[],
  maxRetakeRatio: number = DEFAULT_MAX_RETAKE_RATIO
): Promise<LlmRetake[]> {
  if (rawTokens.length === 0) return [];

  // Collapse whisper sub-word pieces into whole words before indexing so the
  // model sees real words and the index→time mapping below stays aligned.
  const tokens = mergeSubwordTokens(rawTokens);

  const transcript = buildIndexedTranscript(tokens);
  const userPrompt =
    `Here is the transcript as numbered word tokens (token count: ${tokens.length}).\n\n` +
    `${transcript}\n\n` +
    `Find every re-recorded take and call report_retakes.`;

  const messages: Anthropic.MessageParam[] = [
    { role: "user", content: userPrompt },
  ];

  // Attempt 1. A null result (no tool call), a thrown shape error, or a failed
  // semantic check all funnel into a single repair retry below.
  let rawCuts: RetakeCut[] | null = null;
  let firstError = "";
  try {
    rawCuts = await requestRawCuts(client, model, messages);
    if (rawCuts !== null) validateRetakeCuts({ cuts: rawCuts }, tokens.length);
  } catch (err) {
    if (!(err instanceof RetakeValidationError)) throw err;
    firstError = err.message;
    rawCuts = null;
  }

  // Repair retry: covers no-tool-call, bad shape, and semantic-invalid alike.
  if (rawCuts === null) {
    const repairMessages: Anthropic.MessageParam[] = [
      ...messages,
      {
        role: "user",
        content:
          (firstError ? `Your previous tool call was invalid: ${firstError}\n` : "") +
          `You must call the report_retakes tool. Token indices must be within 0..${tokens.length - 1}, with abandonedStartIndex < keepStartIndex <= keepEndIndex, and cuts must be disjoint. ` +
          `If there are genuinely no retakes, call report_retakes with an empty "cuts" array.`,
      },
    ];
    try {
      rawCuts = await requestRawCuts(client, model, repairMessages);
    } catch (err) {
      if (!(err instanceof RetakeValidationError)) throw err;
      rawCuts = null;
    }
  }

  // Still nothing usable after the repair → treat as no retakes (don't fail).
  if (rawCuts === null) return [];

  // Final safety net: drop/clamp anything still invalid instead of failing.
  const { cuts, dropped } = sanitizeRetakeCuts(rawCuts, tokens.length);
  if (dropped.length > 0) {
    console.warn(
      chalk.yellow(
        `Note: dropped ${dropped.length} invalid retake cut(s) the model returned:`
      )
    );
    for (const d of dropped) console.warn(chalk.dim(`  - ${d.reason}`));
  }

  const retakes: LlmRetake[] = [];
  let overlongDropped = 0;
  let sparseDropped = 0;
  for (const c of cuts) {
    // Extend the deletion backward across any exactly-repeated prefix so leading
    // duplication ("So so first...") is removed even if the model anchored late.
    const abandonedStart = refineAbandonedStart(
      tokens,
      c.abandonedStartIndex,
      c.keepStartIndex,
      c.keepEndIndex
    );

    // Delete everything from the start of the abandoned take up to the start of
    // the kept take. End time is the kept take's start (exclusive).
    const start = tokens[abandonedStart].start;
    const end = tokens[c.keepStartIndex].start;

    // Guard against non-monotonic whisper timestamps: index order is validated
    // (abandonedStart < keepStart), but DTW jitter can rarely make the kept
    // word's start time precede the abandoned word's. Such a region is
    // degenerate (snapping/inversion would misbehave), so skip it.
    if (end <= start) continue;

    // Delete-vs-keep ratio guard. A genuine retake deletes about as many words
    // as it keeps; a wildly lopsided ratio means a mis-paired recurring phrase
    // or a transcript loop that would delete large amounts of distinct content.
    const removedTokens = c.keepStartIndex - abandonedStart;
    const keptTokens = c.keepEndIndex - c.keepStartIndex + 1;
    const ratio = removedTokens / Math.max(1, keptTokens);
    if (ratio > maxRetakeRatio) {
      overlongDropped++;
      continue;
    }

    // Word-density guard: a long cut with almost no words is a region whisper
    // failed to transcribe, not a re-recording. Dropping protects real content.
    const span = end - start;
    if (
      span > MIN_SPAN_FOR_DENSITY_CHECK &&
      removedTokens / span < MIN_RETAKE_WORD_DENSITY
    ) {
      sparseDropped++;
      continue;
    }

    // Confidence: the model's self-report, capped by how lopsided the cut is so
    // a suspicious delete/keep ratio can't present as highly confident.
    const confidence = Math.min(
      c.confidence ?? 50,
      ratioConfidenceCap(ratio)
    );

    retakes.push({
      cutRegion: { start, end },
      reason: c.reason,
      removedText: reconstructText(tokens, abandonedStart, c.keepStartIndex - 1),
      keptText: reconstructText(tokens, c.keepStartIndex, c.keepEndIndex),
      contextBefore: sentenceBefore(tokens, abandonedStart - 1),
      contextAfter: sentenceAfter(tokens, c.keepEndIndex + 1),
      confidence,
    });
  }

  if (overlongDropped > 0) {
    console.warn(
      chalk.yellow(
        `Note: dropped ${overlongDropped} cut(s) with an implausible delete-to-keep ratio (> ${maxRetakeRatio}:1) — likely a mis-paired recurring phrase or a looping transcript. Raise --max-retake-ratio to keep them.`
      )
    );
  }
  if (sparseDropped > 0) {
    console.warn(
      chalk.yellow(
        `Note: dropped ${sparseDropped} cut(s) spanning several seconds with almost no words — likely audio whisper couldn't transcribe, not a retake. Left in place to avoid deleting real content.`
      )
    );
  }

  return retakes;
}
