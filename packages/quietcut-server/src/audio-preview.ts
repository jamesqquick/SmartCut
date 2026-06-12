import { execa } from "execa";
import { mkdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";

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
      }
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
  endSec: number
): Promise<{ path: string; durationSec: number }> {
  if (!Number.isFinite(startSec) || !Number.isFinite(endSec)) {
    throw new Error("startSec and endSec must be finite numbers");
  }
  if (endSec <= startSec) {
    throw new Error(`endSec (${endSec}) must be greater than startSec (${startSec})`);
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
    { reject: false }
  );

  if (result.exitCode !== 0) {
    throw new Error(
      `ffmpeg extractClip failed (code ${result.exitCode}):\n${result.stderr ?? ""}`
    );
  }

  scheduleCleanup(outPath);
  return { path: outPath, durationSec: endSec - startSec };
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
  options: { padSec?: number; tailSec?: number } = {}
): Promise<{ path: string; durationSec: number }> {
  if (!Number.isFinite(removeStart) || !Number.isFinite(removeEnd)) {
    throw new Error("removeStart and removeEnd must be finite numbers");
  }
  if (removeEnd <= removeStart) {
    throw new Error(
      `removeEnd (${removeEnd}) must be greater than removeStart (${removeStart})`
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
    { reject: false }
  );

  if (result.exitCode !== 0) {
    throw new Error(
      `ffmpeg extractStitchedClip failed (code ${result.exitCode}):\n${result.stderr ?? ""}`
    );
  }

  scheduleCleanup(outPath);
  return {
    path: outPath,
    durationSec: (leadEnd - leadStart) + (tailEnd - tailStart),
  };
}
