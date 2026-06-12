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
