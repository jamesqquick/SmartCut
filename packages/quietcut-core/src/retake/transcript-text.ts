import type { Token } from "../types.js";

// ---------------------------------------------------------------------------
// Shared helpers for reconstructing display text from a token range.
//
// Used by both the LLM retake detector (to build removed/kept/context strings
// from model-reported token indices) and the batch review path (to rebuild
// those strings after the user adjusts a cut's word boundaries).
// ---------------------------------------------------------------------------

export const MAX_CONTEXT_WORDS = 6;
export const SENTENCE_END = /[.!?]["')\]]?$/;

/**
 * Join tokens [start, end] (inclusive) back into readable text.
 */
export function reconstructText(
  tokens: Token[],
  start: number,
  end: number,
): string {
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
export function sentenceBefore(tokens: Token[], endIdx: number): string {
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
export function sentenceAfter(tokens: Token[], startIdx: number): string {
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
