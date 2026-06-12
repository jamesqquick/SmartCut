import { execa } from "execa";

// Candidate binary names for whisper.cpp CLI across platforms / install methods.
// "main" is intentionally excluded — it's too generic and will false-positive
// match unrelated binaries that happen to be named "main" on PATH.
const WHISPER_CANDIDATES = [
  "whisper-cli",   // whisper.cpp >= v1.7 default binary name
  "whisper",       // some package managers (e.g. pip openai-whisper) use this name
];

/**
 * Find the first whisper CLI binary available on PATH.
 * Returns the binary name, or null if none found.
 */
export async function findWhisperCli(): Promise<string | null> {
  for (const bin of WHISPER_CANDIDATES) {
    try {
      const result = await execa(bin, ["--help"], { reject: false });
      // A missing binary resolves with failed:true and exitCode:undefined.
      // An installed binary exits 0 or 1 (some CLIs exit 1 on --help).
      if (!result.failed || result.exitCode !== undefined) {
        return bin;
      }
    } catch {
      // ENOENT or other spawn error — binary not found
    }
  }
  return null;
}

/**
 * Assert that a whisper CLI binary is available on PATH.
 * Throws a friendly error with install instructions if not found.
 */
export async function assertWhisperAvailable(): Promise<string> {
  const bin = await findWhisperCli();
  if (!bin) {
    throw new Error(
      `whisper-cli not found on PATH. Install whisper.cpp and make sure it is accessible:\n` +
        `  https://github.com/ggerganov/whisper.cpp\n\n` +
        `Quick install (Homebrew):\n` +
        `  brew install whisper-cpp\n\n` +
        `Or build from source:\n` +
        `  git clone https://github.com/ggerganov/whisper.cpp && cd whisper.cpp && make`
    );
  }
  return bin;
}
