import { execa, ExecaError } from "execa";
import { mkdtemp, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

/**
 * Verify ffmpeg and ffprobe are available on PATH.
 * Throws a friendly error if either is missing.
 */
export async function assertFfmpegAvailable(): Promise<void> {
  for (const bin of ["ffmpeg", "ffprobe"]) {
    try {
      await execa(bin, ["-version"], { reject: true });
    } catch {
      throw new Error(
        `"${bin}" not found on PATH. Install ffmpeg and make sure it is accessible:\n  https://ffmpeg.org/download.html`
      );
    }
  }
}

/**
 * Get the duration of a media file in seconds via ffprobe.
 */
export async function getDuration(file: string): Promise<number> {
  const { stdout } = await execa("ffprobe", [
    "-v",
    "error",
    "-show_entries",
    "format=duration",
    "-of",
    "default=noprint_wrappers=1:nokey=1",
    file,
  ]);
  const duration = parseFloat(stdout.trim());
  if (isNaN(duration) || duration <= 0) {
    throw new Error(`Could not determine duration of "${file}".`);
  }
  return duration;
}

/**
 * Run an ffmpeg command and stream progress updates.
 * @param args - ffmpeg arguments (not including the "ffmpeg" binary itself)
 * @param onProgress - called with 0-1 as ffmpeg processes
 * @param totalDurationMs - total output duration in milliseconds for progress calculation
 */
export async function runFfmpeg(
  args: string[],
  onProgress?: (progress: number) => void,
  totalDurationMs?: number
): Promise<void> {
  const proc = execa("ffmpeg", args, {
    reject: false,
    all: true,
  });

  if (onProgress && totalDurationMs && proc.stdout) {
    let buffer = "";
    proc.stdout.on("data", (chunk: Buffer) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const match = line.match(/^out_time_ms=(\d+)/);
        if (match) {
          // ffmpeg's `out_time_ms` is actually microseconds despite the name.
          const microseconds = parseInt(match[1], 10);
          const elapsedMs = microseconds / 1000;
          const progress = Math.min(elapsedMs / totalDurationMs, 1);
          onProgress(progress);
        }
      }
    });
  }

  const result = await proc;

  if (result.exitCode !== 0) {
    const errOutput = result.stderr ?? result.all ?? "";
    throw new Error(`ffmpeg exited with code ${result.exitCode}:\n${errOutput}`);
  }
}

/**
 * Extract a mono 16 kHz PCM WAV from the input file into a temp directory.
 * Returns the path to the WAV file and a cleanup function.
 */
export async function extractAudio(
  input: string
): Promise<{ wavPath: string; cleanup: () => Promise<void> }> {
  const tmpDir = await mkdtemp(join(tmpdir(), "quietcut-"));
  const wavPath = join(tmpDir, "audio.wav");

  const result = await execa(
    "ffmpeg",
    [
      "-hide_banner",
      "-y",
      "-i",
      input,
      "-ac",
      "1",
      "-ar",
      "16000",
      "-c:a",
      "pcm_s16le",
      wavPath,
    ],
    { reject: false }
  );

  if (result.exitCode !== 0) {
    await rm(tmpDir, { recursive: true, force: true });
    throw new Error(
      `ffmpeg audio extraction failed (code ${result.exitCode}):\n${result.stderr}`
    );
  }

  return {
    wavPath,
    cleanup: () => rm(tmpDir, { recursive: true, force: true }),
  };
}
