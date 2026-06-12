/**
 * Format seconds as HH:MM:SS.mmm
 */
export function formatTime(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;

  const hh = String(h).padStart(2, "0");
  const mm = String(m).padStart(2, "0");
  const ss = s.toFixed(3).padStart(6, "0");

  return `${hh}:${mm}:${ss}`;
}

/**
 * Format seconds as a human-readable duration (e.g. 3.450s or 1:23.450)
 */
export function formatDuration(seconds: number): string {
  if (seconds < 60) {
    return `${seconds.toFixed(3)}s`;
  }
  const m = Math.floor(seconds / 60);
  const s = (seconds % 60).toFixed(3).padStart(6, "0");
  return `${m}:${s}`;
}
