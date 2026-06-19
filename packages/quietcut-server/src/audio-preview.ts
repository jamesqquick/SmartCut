import { randomUUID } from "node:crypto";
import { mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execa } from "execa";
import { buildEditPlan, planToKeepSegments, type Segment } from "quietcut-core";

const PREVIEW_DIR = join(tmpdir(), "smartcut-previews");
const TTL_MS = 5 * 60 * 1000;

let dirReady: Promise<void> | null = null;
async function ensureDir(): Promise<void> {
  if (!dirReady) {
    dirReady = mkdir(PREVIEW_DIR, { recursive: true }).then(
      () => undefined,
      (err) => {
        dirReady = null;
        throw err;
      },
    );
  }
  return dirReady;
}

/**
 * Extract a clip from `input` between `startSec` and `endSec` as a PCM WAV
 * for audio-only preview. Returns the absolute path to the temp wav.
 *
 * The file is scheduled for deletion 5 minutes after creation. Callers
 * should treat the path as ephemeral.
 */
export async function extractClip(
  input: string,
  startSec: number,
  endSec: number,
): Promise<{ path: string; durationSec: number }> {
  if (!Number.isFinite(startSec) || !Number.isFinite(endSec)) {
    throw new Error("startSec and endSec must be finite numbers");
  }
  if (endSec <= startSec) {
    throw new Error(
      `endSec (${endSec}) must be greater than startSec (${startSec})`,
    );
  }

  await ensureDir();
  const outPath = join(PREVIEW_DIR, `clip-${randomUUID()}.wav`);

  const result = await execa(
    "ffmpeg",
    [
      "-hide_banner",
      "-y",
      "-ss",
      String(startSec),
      "-to",
      String(endSec),
      "-i",
      input,
      "-vn",
      "-c:a",
      "pcm_s16le",
      "-ac",
      "1",
      "-ar",
      "44100",
      outPath,
    ],
    { reject: false },
  );

  if (result.exitCode !== 0) {
    throw new Error(
      `ffmpeg extractClip failed (code ${result.exitCode}):\n${result.stderr ?? ""}`,
    );
  }

  scheduleCleanup(outPath);
  return { path: outPath, durationSec: endSec - startSec };
}

export type EditedPreviewOptions = {
  padSec?: number;
  tailSec?: number;
  leadInMs?: number;
  tailOutMs?: number;
  cuts?: Segment[];
  silences?: Segment[];
};

/**
 * Render a faithful preview of a single cut boundary. The preview window is
 * [focusStart − padSec, focusEnd + tailSec] in source time. Within that window
 * the function applies every edit the renderer would apply — the cut under
 * review, any neighbouring cuts, silence removals, and lead-in/tail-out
 * padding — by running the same `planToKeepSegments` logic used at render time.
 *
 * The result is a mono PCM WAV whose content is exactly the audio the exported
 * file would contain across that boundary. If there is silence in the 2.5s
 * before the cut, the clip is shorter than 5s — that is correct.
 *
 * @param input      Source video/audio file path.
 * @param duration   Source duration in seconds.
 * @param focusStart Cut start in source seconds (derived from transcript index).
 * @param focusEnd   Cut end / kept-resume in source seconds.
 * @param options    padSec (def 2.5), tailSec (def 2.5), leadInMs (def 300),
 *                   tailOutMs (def 300), cuts (enabled retake+manual segs),
 *                   silences (silence segs).
 */
export async function extractEditedPreview(
  input: string,
  duration: number,
  focusStart: number,
  focusEnd: number,
  options: EditedPreviewOptions = {},
): Promise<{ path: string; durationSec: number }> {
  if (!Number.isFinite(duration) || duration <= 0) {
    throw new Error("duration must be a positive finite number");
  }
  if (!Number.isFinite(focusStart) || !Number.isFinite(focusEnd)) {
    throw new Error("focusStart and focusEnd must be finite numbers");
  }
  if (focusEnd <= focusStart) {
    throw new Error(
      `focusEnd (${focusEnd}) must be greater than focusStart (${focusStart})`,
    );
  }

  const padSec = Math.max(0, options.padSec ?? 2.5);
  const tailSec = Math.max(0, options.tailSec ?? 2.5);
  const leadInMs = Math.max(0, options.leadInMs ?? 300);
  const tailOutMs = Math.max(0, options.tailOutMs ?? 300);
  const cuts = options.cuts ?? [];
  const silences = options.silences ?? [];

  // Window in source time — clamped to file bounds.
  const windowStart = Math.max(0, focusStart - padSec);
  const windowEnd = Math.min(duration, focusEnd + tailSec);

  // Build a throwaway EditPlan from the client-supplied segments.
  // Manual cuts behave like retakes (hard join, no padding bleed).
  const operations = [
    ...cuts.map((s) => ({
      type: "removeRetake" as const,
      start: s.start,
      end: s.end,
      reason: "",
      removedText: "",
      keptText: "",
      contextBefore: "",
      contextAfter: "",
      confidence: 100,
    })),
    ...silences.map((s) => ({
      type: "removeSilence" as const,
      start: s.start,
      end: s.end,
    })),
  ];
  const plan = buildEditPlan(input, duration, operations);
  const keepAll = planToKeepSegments(plan, leadInMs, tailOutMs);

  // Intersect keep segments with the preview window.
  const windowed = keepAll
    .map((seg) => ({
      start: Math.max(seg.start, windowStart),
      end: Math.min(seg.end, windowEnd),
    }))
    .filter((seg) => seg.end - seg.start > 1e-6);

  if (windowed.length === 0) {
    throw new Error(
      "The preview window is entirely removed by the current edit plan. " +
        "Enable at least one cut in the window or widen the preview.",
    );
  }

  await ensureDir();
  const outPath = join(PREVIEW_DIR, `edited-preview-${randomUUID()}.wav`);

  // Build a filter_complex: one atrim per windowed segment, then concat all.
  const filterParts: string[] = windowed.map(
    (seg, i) =>
      `[0:a]atrim=start=${seg.start}:end=${seg.end},asetpts=PTS-STARTPTS[a${i}]`,
  );
  const concatInputs = windowed.map((_, i) => `[a${i}]`).join("");
  filterParts.push(`${concatInputs}concat=n=${windowed.length}:v=0:a=1[aout]`);
  const filter = filterParts.join(";");

  const result = await execa(
    "ffmpeg",
    [
      "-hide_banner",
      "-y",
      "-i",
      input,
      "-filter_complex",
      filter,
      "-map",
      "[aout]",
      "-vn",
      "-c:a",
      "pcm_s16le",
      "-ac",
      "1",
      "-ar",
      "44100",
      outPath,
    ],
    { reject: false },
  );

  if (result.exitCode !== 0) {
    throw new Error(
      `ffmpeg extractEditedPreview failed (code ${result.exitCode}):\n${result.stderr ?? ""}`,
    );
  }

  const durationSec = windowed.reduce(
    (sum, seg) => sum + (seg.end - seg.start),
    0,
  );

  scheduleCleanup(outPath);
  return { path: outPath, durationSec };
}

function scheduleCleanup(path: string): void {
  const timer = setTimeout(() => {
    rm(path, { force: true }).catch(() => {
      // best-effort
    });
  }, TTL_MS);
  // Don't keep the event loop alive just for cleanup.
  timer.unref();
}

/**
 * Render a "stitched preview" clip: a few seconds of audio leading up to
 * the cut, the kept take right after the cut, and a tail of context.
 * Used by the retake review card so the user can hear what the result
 * will sound like with the proposed cut applied.
 *
 *   [ removeStart - padSec ... removeStart ] + [ removeEnd ... removeEnd + tailSec ]
 *
 * Both halves are mono PCM and concatenated in a single ffmpeg pass.
 */
export async function extractStitchedClip(
  input: string,
  removeStart: number,
  removeEnd: number,
  options: { padSec?: number; tailSec?: number } = {},
): Promise<{ path: string; durationSec: number }> {
  if (!Number.isFinite(removeStart) || !Number.isFinite(removeEnd)) {
    throw new Error("removeStart and removeEnd must be finite numbers");
  }
  if (removeEnd <= removeStart) {
    throw new Error(
      `removeEnd (${removeEnd}) must be greater than removeStart (${removeStart})`,
    );
  }

  const padSec = Math.max(0, options.padSec ?? 1.5);
  const tailSec = Math.max(0, options.tailSec ?? 4.0);
  const leadStart = Math.max(0, removeStart - padSec);
  const leadEnd = removeStart;
  const tailStart = removeEnd;
  const tailEnd = removeEnd + tailSec;

  await ensureDir();
  const outPath = join(PREVIEW_DIR, `stitched-${randomUUID()}.wav`);

  // Trim two regions out of the source and concat them.
  const filter =
    `[0:a]atrim=start=${leadStart}:end=${leadEnd},asetpts=PTS-STARTPTS[a0];` +
    `[0:a]atrim=start=${tailStart}:end=${tailEnd},asetpts=PTS-STARTPTS[a1];` +
    `[a0][a1]concat=n=2:v=0:a=1[a]`;

  const result = await execa(
    "ffmpeg",
    [
      "-hide_banner",
      "-y",
      "-i",
      input,
      "-filter_complex",
      filter,
      "-map",
      "[a]",
      "-vn",
      "-c:a",
      "pcm_s16le",
      "-ac",
      "1",
      "-ar",
      "44100",
      outPath,
    ],
    { reject: false },
  );

  if (result.exitCode !== 0) {
    throw new Error(
      `ffmpeg extractStitchedClip failed (code ${result.exitCode}):\n${result.stderr ?? ""}`,
    );
  }

  scheduleCleanup(outPath);
  return {
    path: outPath,
    durationSec: leadEnd - leadStart + (tailEnd - tailStart),
  };
}
