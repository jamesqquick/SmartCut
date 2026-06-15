import type { RetakeMatch, Segment, Token } from "../types.js";

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

interface RetakeMatchInternal {
  matchedPhrase: string;
  firstTake: { start: number; end: number; text: string };
  secondTake: { start: number; end: number; text: string };
  cutRegion: Segment;
  firstTakeTokenRange: [number, number]; // [startIdx, endIdx] into working[]
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Find all retake regions in the token list.
 *
 * Strategy:
 *   1. Single forward scan, comparing non-filler n-grams.
 *   2. Filler tokens on either side of a match are skipped (their time is
 *      included in the take boundaries but don't count toward minWords).
 *   3. After finding all matches in a pass, remove first-take tokens from the
 *      working list and repeat — handles triple (or more) retakes so that only
 *      the final take survives.
 *   4. Results are sorted chronologically before returning.
 */
export function detectRetakes(
  tokens: Token[],
  minWords: number,
  maxGapSeconds: number,
): RetakeMatch[] {
  const allMatches: RetakeMatchInternal[] = [];

  let working = [...tokens];

  // Iterate until no new matches are found (handles 3+ retakes)
  while (true) {
    const passMatches = findMatches(working, minWords, maxGapSeconds);
    if (passMatches.length === 0) break;

    allMatches.push(...passMatches);

    // Remove first-take tokens so next pass sees the cleaned-up sequence.
    const toRemove = new Set<number>();
    for (const m of passMatches) {
      for (
        let i = m.firstTakeTokenRange[0];
        i <= m.firstTakeTokenRange[1];
        i++
      ) {
        toRemove.add(i);
      }
    }
    working = working.filter((_, idx) => !toRemove.has(idx));
  }

  // Sort by start time of the cut region and strip internal fields
  allMatches.sort((a, b) => a.cutRegion.start - b.cutRegion.start);

  return allMatches.map(
    ({ matchedPhrase, firstTake, secondTake, cutRegion }): RetakeMatch => ({
      matchedPhrase,
      firstTake,
      secondTake,
      cutRegion,
    }),
  );
}

// ---------------------------------------------------------------------------
// Single-pass match finder
// ---------------------------------------------------------------------------

function findMatches(
  tokens: Token[],
  minWords: number,
  maxGapSeconds: number,
): RetakeMatchInternal[] {
  const matches: RetakeMatchInternal[] = [];
  // Track which token indices are already claimed as part of a first-take so
  // we don't double-report overlapping matches.
  const claimed = new Set<number>();

  const nonFiller = tokens
    .map((t, i) => ({ token: t, idx: i }))
    .filter(({ token }) => !token.isFiller);

  for (let ai = 0; ai < nonFiller.length; ai++) {
    if (claimed.has(nonFiller[ai].idx)) continue;

    // Try every subsequent non-filler token as the start of a potential second take
    for (let bi = ai + 1; bi < nonFiller.length; bi++) {
      if (claimed.has(nonFiller[bi].idx)) continue;

      const a = nonFiller[ai];
      const b = nonFiller[bi];

      // Words must match at the anchor
      if (a.token.normalized !== b.token.normalized) continue;

      // Gap between end of a-sequence and start of b must be within maxGap.
      // We use the raw token times here; the gap includes any filler between them.
      const gapStart = a.token.end;
      const gapEnd = b.token.start;
      if (gapEnd - gapStart > maxGapSeconds) continue;

      // Extend both sequences forward as far as non-filler words keep matching
      let matchLen = 1;
      let aii = ai + 1;
      let bii = bi + 1;

      while (aii < nonFiller.length && bii < nonFiller.length) {
        const nextA = nonFiller[aii];
        const nextB = nonFiller[bii];
        if (nextA.token.normalized !== nextB.token.normalized) break;
        matchLen++;
        aii++;
        bii++;
      }

      if (matchLen < minWords) continue;

      // Determine the full token-index ranges (including filler) for each take.
      // First take: tokens[nonFiller[ai].idx .. nonFiller[ai + matchLen - 1].idx]
      const firstStartIdx = nonFiller[ai].idx;
      const firstEndIdx = nonFiller[ai + matchLen - 1].idx;
      // Second take starts at nonFiller[bi].idx
      const secondStartIdx = nonFiller[bi].idx;
      const secondEndIdx = nonFiller[bi + matchLen - 1].idx;

      // Skip if any of these are already claimed
      let alreadyClaimed = false;
      for (let k = firstStartIdx; k <= firstEndIdx; k++) {
        if (claimed.has(k)) {
          alreadyClaimed = true;
          break;
        }
      }
      if (alreadyClaimed) continue;

      // Build take text.
      // First take: show only the matched phrase (that's all that gets removed).
      // Second take: extend forward up to 5 more non-filler words so the user
      // can see how the sentence continues after the repeated phrase.
      const firstText = buildTakeText(tokens, firstStartIdx, firstEndIdx);
      const secondExtendedEndIdx = extendForward(
        nonFiller,
        bi + matchLen - 1,
        tokens.length,
        5,
      );
      const secondText = buildTakeText(
        tokens,
        secondStartIdx,
        secondExtendedEndIdx,
      );
      const matchedPhrase = nonFiller
        .slice(ai, ai + matchLen)
        .map(({ token }) => token.word)
        .join(" ");

      // Cut region = everything from first-take start to second-take start
      // (we remove the first take up to where the second begins).
      const cutRegion: Segment = {
        start: tokens[firstStartIdx].start,
        end: tokens[secondStartIdx].start,
      };

      matches.push({
        matchedPhrase,
        firstTake: {
          start: tokens[firstStartIdx].start,
          end: tokens[firstEndIdx].end,
          text: firstText,
        },
        secondTake: {
          start: tokens[secondStartIdx].start,
          end: tokens[secondEndIdx].end,
          text: secondText,
        },
        cutRegion,
        firstTakeTokenRange: [firstStartIdx, firstEndIdx],
      });

      // Claim first-take indices
      for (let k = firstStartIdx; k <= firstEndIdx; k++) {
        claimed.add(k);
      }

      // Advance outer loop past the matched block
      ai = ai + matchLen - 1;
      break; // move to next ai anchor
    }
  }

  return matches;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Collect the display text for a take by joining tokens in the given index range,
 * including filler tokens that fall within the range.
 */
function buildTakeText(
  tokens: Token[],
  startIdx: number,
  endIdx: number,
): string {
  return tokens
    .slice(startIdx, endIdx + 1)
    .map((t) => t.word)
    .join(" ")
    .trim();
}

/**
 * Advance forward from nonFiller[nfIdx] by up to `count` more non-filler
 * words and return the raw token index of the last one reached.
 */
function extendForward(
  nonFiller: Array<{ token: Token; idx: number }>,
  nfIdx: number,
  _tokenCount: number,
  count: number,
): number {
  const target = Math.min(nfIdx + count, nonFiller.length - 1);
  return nonFiller[target].idx;
}
