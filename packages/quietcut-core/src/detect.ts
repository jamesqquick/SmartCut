import { execa } from "execa";
import type { Config, DetectionResult, Segment } from "./types.js";

/**
 * Run ffmpeg silencedetect on the input file and parse the results.
 * Returns the total duration and a list of silence segments.
 */
export async function detectSilences(
  config: Config,
  duration: number,
  audioPath?: string,
): Promise<DetectionResult> {
  const { thresholdDb, minSilence } = config;
  const inputFile = audioPath ?? config.input;

  const { stderr } = await execa(
    "ffmpeg",
    [
      "-hide_banner",
      "-nostats",
      "-i",
      inputFile,
      "-af",
      `silencedetect=noise=${thresholdDb}dB:d=${minSilence}`,
      "-f",
      "null",
      "-",
    ],
    { reject: false, all: false },
  );

  const silences = parseSilences(stderr ?? "", duration);

  return { duration, silences };
}

/**
 * Parse silence_start / silence_end lines from ffmpeg stderr.
 * Handles trailing open silences (file ends in silence) by closing at duration.
 */
function parseSilences(stderr: string, duration: number): Segment[] {
  const silences: Segment[] = [];
  let currentStart: number | null = null;

  for (const line of stderr.split("\n")) {
    const startMatch = line.match(/silence_start:\s*([\d.]+)/);
    const endMatch = line.match(/silence_end:\s*([\d.]+)/);

    if (startMatch) {
      currentStart = parseFloat(startMatch[1]);
    }

    if (endMatch && currentStart !== null) {
      silences.push({ start: currentStart, end: parseFloat(endMatch[1]) });
      currentStart = null;
    }
  }

  // File ends in silence — close the open segment at duration
  if (currentStart !== null) {
    silences.push({ start: currentStart, end: duration });
  }

  return silences;
}
