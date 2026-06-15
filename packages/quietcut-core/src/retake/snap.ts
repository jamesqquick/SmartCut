import type { RetakeMatch, Segment } from "../types.js";

const SNAP_WINDOW_SECONDS = 0.5;

/**
 * Snap a cut region's start and end boundaries to the nearest silence boundary
 * within SNAP_WINDOW_SECONDS. This avoids cutting mid-breath or mid-word.
 *
 * If no silence boundary is within the window the original time is kept.
 */
export function snapToCutRegion(
  cutRegion: Segment,
  silences: Segment[],
): Segment {
  return {
    start: snapTime(cutRegion.start, silences, "end"),
    end: snapTime(cutRegion.end, silences, "start"),
  };
}

/**
 * Snap all cut regions in an array of RetakeMatches.
 */
export function snapMatches(
  matches: RetakeMatch[],
  silences: Segment[],
): RetakeMatch[] {
  return matches.map((m) => ({
    ...m,
    cutRegion: snapToCutRegion(m.cutRegion, silences),
  }));
}

/**
 * Snap a smartcut retake cut region to silence so the join lands on real audio
 * edges instead of jittered whisper word timestamps.
 *
 * The START maps to the END of a silence (the instant the abandoned take's
 * audio begins). whisper's DTW word timestamps drift — frequently landing
 * *inside* the adjacent pause — so we snap with a containment-first strategy:
 *   1. If the time falls inside a silence region, snap to that region's end
 *      (handles arbitrary jitter).
 *   2. Otherwise snap to the nearest silence end within SNAP_WINDOW_SECONDS.
 *   3. If neither applies, keep the original time.
 *
 * The END is the kept take's onset, and is treated CONSERVATIVELY: it may snap
 * *earlier* to a silence edge (trimming a little pre-roll pause) but must NEVER
 * advance past the kept word's onset, or it would clip the first word of the
 * kept take (e.g. eating the second "Now" in "Now we're gonna see / Now we're
 * gonna see"). Soft word onsets dip below the silence threshold, so the silence
 * that precedes a kept word can end slightly *after* the word actually starts;
 * snapping forward to that silence end is what caused the clipping. We therefore
 * clamp the snapped end to the original (unsnapped) kept-word onset. Any small
 * residual pre-kept pause is handled by the normal silence pass (pauses below
 * --min-silence are a benign breath).
 *
 * A final guard prevents the snapped region from inverting: if the end lands at
 * or before the start, the original unsnapped region is returned. Callers
 * guarantee the unsnapped region is non-degenerate (end > start).
 */
export function snapRetakeCutRegion(
  cutRegion: Segment,
  silences: Segment[],
): Segment {
  const start = snapToSilenceEnd(cutRegion.start, silences);
  // Never let the end advance past the kept word's onset (clip protection).
  const end = Math.min(
    cutRegion.end,
    snapToSilenceEnd(cutRegion.end, silences),
  );
  // Snapping must never invert or collapse the cut; if it would, keep original.
  if (end <= start) return { start: cutRegion.start, end: cutRegion.end };
  return { start, end };
}

/**
 * Snap a time to the end of a silence region: the moment audio resumes.
 * Containment-first (any jitter), then nearest end within the window.
 */
function snapToSilenceEnd(time: number, silences: Segment[]): number {
  for (const s of silences) {
    if (time >= s.start && time <= s.end) return s.end;
  }

  let best = time;
  let bestDist = Infinity;
  for (const s of silences) {
    const dist = Math.abs(s.end - time);
    if (dist < bestDist && dist <= SNAP_WINDOW_SECONDS) {
      bestDist = dist;
      best = s.end;
    }
  }
  return best;
}

// ---------------------------------------------------------------------------
// Internal
// ---------------------------------------------------------------------------

/**
 * Find the silence boundary closest to `time` within SNAP_WINDOW_SECONDS.
 *
 * @param side "end"   — snap to the end of a silence (= natural audio resumes)
 *             "start" — snap to the start of a silence (= natural audio ends)
 */
function snapTime(
  time: number,
  silences: Segment[],
  side: "start" | "end",
): number {
  let best = time;
  let bestDist = Infinity;

  for (const s of silences) {
    const candidate = side === "end" ? s.end : s.start;
    const dist = Math.abs(candidate - time);
    if (dist < bestDist && dist <= SNAP_WINDOW_SECONDS) {
      bestDist = dist;
      best = candidate;
    }
  }

  return best;
}
