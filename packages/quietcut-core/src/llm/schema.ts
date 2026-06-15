import { z } from "zod";

// ---------------------------------------------------------------------------
// Schema for the `report_retakes` tool input returned by the LLM.
//
// The model returns token INDICES only; it never emits timestamps. Each cut is
// defined by three indices:
//   - abandonedStartIndex: first word of the earlier attempt(s) to delete.
//   - keepStartIndex:      first word of the final take to keep.
//   - keepEndIndex:        last word of the final take.
//
// The deleted region is [abandonedStartIndex, keepStartIndex) — i.e. everything
// from the start of the abandoned attempt up to (not including) the start of
// the final take. This removes the earlier take plus any filler/false-starts
// between the two takes, so no `remove.end` boundary can drift out of alignment.
//
// Bounds and ordering are checked against the token count in validateRetakeCuts.
// ---------------------------------------------------------------------------

export const retakeCutSchema = z.object({
  abandonedStartIndex: z.number().int().nonnegative(),
  keepStartIndex: z.number().int().nonnegative(),
  keepEndIndex: z.number().int().nonnegative(),
  reason: z.string().trim().min(1, "reason must not be empty"),
  // Model's self-reported confidence (0–100) that this is a genuine retake.
  // Lenient: accept any number and clamp later, so a stray 0–1 or >100 value
  // can't trigger a repair retry. Defaults to 50 when omitted.
  confidence: z.number().optional(),
});

export const retakeToolInputSchema = z.object({
  cuts: z.array(retakeCutSchema),
});

export type RetakeCut = z.infer<typeof retakeCutSchema>;
export type RetakeToolInput = z.infer<typeof retakeToolInputSchema>;

/**
 * JSON Schema passed to the Anthropic tool definition. Hand-written (rather than
 * generated) so the tool contract stays explicit and decoupled from the Zod
 * version's JSON-schema emitter.
 */
export const retakeToolJsonSchema = {
  type: "object",
  properties: {
    cuts: {
      type: "array",
      description:
        "Each detected retake. Everything from abandonedStartIndex up to (not including) keepStartIndex is deleted.",
      items: {
        type: "object",
        properties: {
          abandonedStartIndex: {
            type: "integer",
            description:
              "Index of the FIRST word of the earlier attempt(s) to delete.",
          },
          keepStartIndex: {
            type: "integer",
            description:
              "Index of the FIRST word of the final take to keep. Must be greater than abandonedStartIndex.",
          },
          keepEndIndex: {
            type: "integer",
            description:
              "Index of the LAST word of the final take to keep. Must be >= keepStartIndex.",
          },
          reason: {
            type: "string",
            description: "Short explanation of why this is a retake.",
          },
          confidence: {
            type: "integer",
            description:
              "Your confidence from 0 to 100 that this is a genuine re-recorded retake (not rhetorical repetition or a recurring phrase). 100 = certain.",
          },
        },
        required: [
          "abandonedStartIndex",
          "keepStartIndex",
          "keepEndIndex",
          "reason",
          "confidence",
        ],
      },
    },
  },
  required: ["cuts"],
} as const;

export class RetakeValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RetakeValidationError";
  }
}

/**
 * Validate parsed tool input against the token count and cross-cut invariants.
 *
 * - every index within [0, tokenCount)
 * - abandonedStartIndex < keepStartIndex <= keepEndIndex
 * - deletion regions [abandonedStartIndex, keepStartIndex) do not overlap, and
 *   each cut starts after the previous cut's kept take ends
 *
 * Throws RetakeValidationError with an LLM-readable message (used for the
 * single repair retry).
 */
export function validateRetakeCuts(
  input: RetakeToolInput,
  tokenCount: number,
): RetakeCut[] {
  const cuts = input.cuts;

  for (let i = 0; i < cuts.length; i++) {
    const c = cuts[i];
    for (const [label, idx] of [
      ["abandonedStartIndex", c.abandonedStartIndex],
      ["keepStartIndex", c.keepStartIndex],
      ["keepEndIndex", c.keepEndIndex],
    ] as const) {
      if (idx >= tokenCount) {
        throw new RetakeValidationError(
          `cuts[${i}].${label} (${idx}) is out of range (max ${tokenCount - 1}).`,
        );
      }
    }
    if (c.abandonedStartIndex >= c.keepStartIndex) {
      throw new RetakeValidationError(
        `cuts[${i}]: abandonedStartIndex (${c.abandonedStartIndex}) must be less than keepStartIndex (${c.keepStartIndex}).`,
      );
    }
    if (c.keepStartIndex > c.keepEndIndex) {
      throw new RetakeValidationError(
        `cuts[${i}]: keepStartIndex (${c.keepStartIndex}) must be <= keepEndIndex (${c.keepEndIndex}).`,
      );
    }
  }

  // Cuts must be disjoint and ordered: each cut must start after the previous
  // cut's kept take ends.
  const sorted = [...cuts].sort(
    (a, b) => a.abandonedStartIndex - b.abandonedStartIndex,
  );
  for (let i = 1; i < sorted.length; i++) {
    const prev = sorted[i - 1];
    const curr = sorted[i];
    if (curr.abandonedStartIndex <= prev.keepEndIndex) {
      throw new RetakeValidationError(
        `cuts overlap: a cut starting at ${curr.abandonedStartIndex} begins before the previous kept take ends at ${prev.keepEndIndex}. Cuts must be disjoint.`,
      );
    }
  }

  return cuts;
}

export type DroppedCut = { reason: string };

/**
 * Best-effort cleanup of model-returned cuts. Unlike `validateRetakeCuts` (which
 * throws to drive the repair retry), this never throws: it repairs trivially
 * recoverable mistakes and discards cuts it cannot trust, returning the survivors
 * plus a list of what was dropped and why.
 *
 * Used as the final safety net so one malformed cut (e.g. a single off-by-one
 * index in a long transcript) cannot abort the entire job. Per-cut human review
 * is the backstop for anything that slips through.
 *
 * Repairs/decisions:
 * - `keepEndIndex === tokenCount` (off-by-one past the end) is clamped to the
 *   last valid index.
 * - any index still out of `[0, tokenCount)` → drop the cut.
 * - `abandonedStartIndex < keepStartIndex <= keepEndIndex` must hold → else drop.
 * - overlapping cuts are resolved greedily (keep the earliest, drop later
 *   cuts that start before the previous kept take ends).
 */
export function sanitizeRetakeCuts(
  cuts: RetakeCut[],
  tokenCount: number,
): { cuts: RetakeCut[]; dropped: DroppedCut[] } {
  const dropped: DroppedCut[] = [];
  const cleaned: RetakeCut[] = [];

  for (const original of cuts) {
    const c = { ...original };

    // Normalize confidence into [0, 100]; default to 50 when missing/garbage.
    const conf =
      typeof c.confidence === "number" && Number.isFinite(c.confidence)
        ? Math.max(0, Math.min(100, Math.round(c.confidence)))
        : 50;
    c.confidence = conf;

    // Clamp a single off-by-one on the (inclusive) kept-take end.
    if (c.keepEndIndex === tokenCount) c.keepEndIndex = tokenCount - 1;

    const indices = [c.abandonedStartIndex, c.keepStartIndex, c.keepEndIndex];
    if (indices.some((idx) => idx < 0 || idx >= tokenCount)) {
      dropped.push({
        reason: `index out of range (valid 0..${tokenCount - 1}): abandoned=${c.abandonedStartIndex}, keepStart=${c.keepStartIndex}, keepEnd=${c.keepEndIndex}`,
      });
      continue;
    }
    if (c.abandonedStartIndex >= c.keepStartIndex) {
      dropped.push({
        reason: `abandonedStartIndex (${c.abandonedStartIndex}) not before keepStartIndex (${c.keepStartIndex})`,
      });
      continue;
    }
    if (c.keepStartIndex > c.keepEndIndex) {
      dropped.push({
        reason: `keepStartIndex (${c.keepStartIndex}) after keepEndIndex (${c.keepEndIndex})`,
      });
      continue;
    }
    cleaned.push(c);
  }

  // Resolve overlaps greedily: keep the earliest cut, drop any later cut that
  // begins before the previous kept take ends.
  cleaned.sort((a, b) => a.abandonedStartIndex - b.abandonedStartIndex);
  const disjoint: RetakeCut[] = [];
  let lastKeepEnd = -1;
  for (const c of cleaned) {
    if (c.abandonedStartIndex <= lastKeepEnd) {
      dropped.push({
        reason: `overlaps previous cut (starts at ${c.abandonedStartIndex}, previous kept take ends at ${lastKeepEnd})`,
      });
      continue;
    }
    disjoint.push(c);
    lastKeepEnd = c.keepEndIndex;
  }

  return { cuts: disjoint, dropped };
}
