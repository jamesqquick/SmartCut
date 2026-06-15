import { stat } from "node:fs/promises";
import { execa } from "execa";

export type VideoMetadata = {
  durationSec: number;
  sizeBytes: number;
  codec?: string;
  width?: number;
  height?: number;
};

/**
 * Read basic metadata for a media file. Uses ffprobe for the duration
 * and stream details, fs.stat for file size.
 */
export async function getMetadata(path: string): Promise<VideoMetadata> {
  const stats = await stat(path).catch(() => null);
  if (!stats) {
    throw new Error(`File not found: ${path}`);
  }

  const { stdout } = await execa("ffprobe", [
    "-v",
    "error",
    "-print_format",
    "json",
    "-show_format",
    "-show_streams",
    path,
  ]);

  let probe: ProbeOutput;
  try {
    probe = JSON.parse(stdout) as ProbeOutput;
  } catch (err) {
    throw new Error(
      `Could not parse ffprobe output for ${path}: ${(err as Error).message}`,
    );
  }

  const duration = parseFloat(probe.format?.duration ?? "");
  if (!Number.isFinite(duration) || duration <= 0) {
    throw new Error(`Could not determine duration of ${path}`);
  }

  const video = probe.streams?.find((s) => s.codec_type === "video");
  return {
    durationSec: duration,
    sizeBytes: stats.size,
    codec: video?.codec_name,
    width: video?.width,
    height: video?.height,
  };
}

type ProbeOutput = {
  format?: { duration?: string };
  streams?: Array<{
    codec_type?: string;
    codec_name?: string;
    width?: number;
    height?: number;
  }>;
};
