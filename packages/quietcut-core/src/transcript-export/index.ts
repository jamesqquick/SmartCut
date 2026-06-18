import { writeFile } from "node:fs/promises";
import { basename } from "node:path";
import type { EditPlan } from "../edit-plan.js";
import { planToKeepSegments } from "../edit-plan.js";
import type { TranscriptToken } from "../types.js";
import { formatAiJson } from "./ai-json.js";
import { editedDuration, remapTranscript } from "./remap.js";
import { formatSrt } from "./srt.js";

// ---------------------------------------------------------------------------
// Transcript export — public entry points.
//
// Both formats are derived from the original-timeline transcript plus the final
// EditPlan: words inside cut regions are dropped and survivors are re-timed onto
// the rendered (edited) timeline. There is no second transcription pass.
// ---------------------------------------------------------------------------

export type { AiTranscript, AiTranscriptMeta } from "./ai-json.js";
export { buildAiTranscript, formatAiJson } from "./ai-json.js";
export type { TranscriptSegment } from "./group.js";
export { groupIntoSegments } from "./group.js";
export { editedDuration, remapTranscript } from "./remap.js";
export { formatSrt, formatSrtTimestamp } from "./srt.js";

export type EditedTranscript = {
  /** Edited-timeline words (cut words removed, timings re-based to 0). */
  words: TranscriptToken[];
  /** Total duration of the edited timeline, in seconds. */
  duration: number;
};

/**
 * Produce the edited-timeline transcript from the original word tokens and the
 * final plan. Uses the same keep-segment computation the renderer consumes, so
 * the result aligns with the exported video (padding included).
 */
export function buildEditedTranscript(
  transcript: TranscriptToken[],
  plan: EditPlan,
  leadInMs: number,
  tailOutMs: number,
): EditedTranscript {
  const keep = planToKeepSegments(plan, leadInMs, tailOutMs);
  return {
    words: remapTranscript(transcript, keep),
    duration: editedDuration(keep),
  };
}

export type TranscriptExportFormat = "srt" | "ai-json";

/**
 * Render an edited transcript to a string in the requested format. `source` is
 * the original input path, used for the AI JSON `source` field.
 */
export function formatTranscriptExport(
  edited: EditedTranscript,
  format: TranscriptExportFormat,
  source: string,
): string {
  if (format === "srt") return formatSrt(edited.words);
  return formatAiJson(edited.words, {
    source: basename(source),
    duration: edited.duration,
  });
}

/**
 * Convenience writer: build the edited transcript, format it, and write it to
 * disk. Returns the edited transcript so callers can report word counts.
 */
export async function writeTranscriptExport(
  outputPath: string,
  format: TranscriptExportFormat,
  transcript: TranscriptToken[],
  plan: EditPlan,
  leadInMs: number,
  tailOutMs: number,
): Promise<EditedTranscript> {
  const edited = buildEditedTranscript(transcript, plan, leadInMs, tailOutMs);
  await writeFile(
    outputPath,
    formatTranscriptExport(edited, format, plan.source),
    "utf8",
  );
  return edited;
}
