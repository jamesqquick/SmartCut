import path from "node:path";

/**
 * Derive default output path: inserts "-cut" before the extension.
 * e.g. /videos/recording.mp4 -> /videos/recording-cut.mp4
 */
export function defaultOutput(input: string): string {
  const ext = path.extname(input);
  const base = path.basename(input, ext);
  const dir = path.dirname(input);
  return path.join(dir, `${base}-cut${ext}`);
}

/**
 * Derive default retake output path: inserts "-retake" before the extension.
 * e.g. /videos/recording.mp4 -> /videos/recording-retake.mp4
 */
export function defaultRetakeOutput(input: string): string {
  const ext = path.extname(input);
  const base = path.basename(input, ext);
  const dir = path.dirname(input);
  return path.join(dir, `${base}-retake${ext}`);
}

/**
 * Derive default clean output path: inserts "-clean" before the extension.
 * e.g. /videos/recording.mp4 -> /videos/recording-clean.mp4
 */
export function defaultCleanOutput(input: string): string {
  const ext = path.extname(input);
  const base = path.basename(input, ext);
  const dir = path.dirname(input);
  return path.join(dir, `${base}-clean${ext}`);
}

/**
 * Derive default smartcut output path: inserts "-smart" before the extension.
 * e.g. /videos/recording.mp4 -> /videos/recording-smart.mp4
 */
export function defaultSmartcutOutput(input: string): string {
  const ext = path.extname(input);
  const base = path.basename(input, ext);
  const dir = path.dirname(input);
  return path.join(dir, `${base}-smart${ext}`);
}

const SUPPORTED_EXTENSIONS = new Set([".mp4", ".mov", ".mkv", ".webm"]);

export function warnIfUnsupportedContainer(input: string): string | null {
  const ext = path.extname(input).toLowerCase();
  if (!SUPPORTED_EXTENSIONS.has(ext)) {
    return `Warning: input container "${ext}" is not tested. Output may be unreliable. Consider using mp4, mov, mkv, or webm.`;
  }
  return null;
}
