import { execa } from "execa";
import { readFile, writeFile, mkdtemp, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { extractAudio } from "../utils/ffmpeg.js";
import { assertWhisperAvailable } from "../utils/whisper.js";
import { formatTime } from "../utils/time.js";
import type { Token, RetakeConfig } from "../types.js";

// ---------------------------------------------------------------------------
// Whisper JSON output shape (whisper.cpp -oj -ojf --dtw <model>)
// ---------------------------------------------------------------------------

interface WhisperToken {
  text: string;
  timestamps: { from: string; to: string };
  offsets: { from: number; to: number }; // milliseconds
  t_dtw?: number;
}

interface WhisperSegment {
  text: string;
  timestamps: { from: string; to: string };
  offsets: { from: number; to: number };
  tokens: WhisperToken[];
}

interface WhisperOutput {
  transcription: WhisperSegment[];
}

// ---------------------------------------------------------------------------
// Normalisation
// ---------------------------------------------------------------------------

const FILLER_DEFAULTS = new Set([
  "um", "uh", "like", "so", "okay", "ok", "right", "yeah",
  "uh-huh", "uhh", "umm", "hmm", "hm", "er", "err",
]);

// Whisper special tokens to skip (begin-of-sentence markers, etc.)
const SPECIAL_TOKEN_RE = /^\[.*\]$/;

// A run of this many identical consecutive segments is treated as a whisper
// hallucination loop (a real retake is at most a few attempts) and collapsed to
// a single representative segment before tokenizing.
const LOOP_RUN_THRESHOLD = 6;

function normalizeSegmentText(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

type CollapsedRun = {
  text: string;
  count: number;
  fromSec: number;
  toSec: number;
};

/**
 * Collapse runs of identical consecutive segments (whisper hallucination loops,
 * where one sentence repeats dozens/hundreds of times) down to a single segment.
 * Returns the cleaned segments plus a description of each collapsed run so the
 * caller can warn that the transcript was degraded.
 */
export function collapseRepeatedSegments(segments: WhisperSegment[]): {
  segments: WhisperSegment[];
  collapsed: CollapsedRun[];
} {
  const out: WhisperSegment[] = [];
  const collapsed: CollapsedRun[] = [];

  let i = 0;
  while (i < segments.length) {
    const norm = normalizeSegmentText(segments[i].text);
    let j = i + 1;
    while (
      j < segments.length &&
      norm.length > 0 &&
      normalizeSegmentText(segments[j].text) === norm
    ) {
      j++;
    }
    const runLength = j - i;
    if (runLength >= LOOP_RUN_THRESHOLD) {
      out.push(segments[i]); // keep one representative
      collapsed.push({
        text: segments[i].text.trim(),
        count: runLength,
        fromSec: segments[i].offsets.from / 1000,
        toSec: segments[j - 1].offsets.to / 1000,
      });
    } else {
      for (let k = i; k < j; k++) out.push(segments[k]);
    }
    i = j;
  }

  return { segments: out, collapsed };
}

/**
 * Warn (once per parse) when the transcript contained hallucination loops.
 */
function warnOnCollapsedRuns(collapsed: CollapsedRun[]): void {
  if (collapsed.length === 0) return;
  const biggest = [...collapsed].sort((a, b) => b.count - a.count)[0];
  console.warn(
    `Note: transcript contained ${collapsed.length} repeated-line loop(s) — likely a whisper mis-transcription, not real speech. Collapsed them.`
  );
  console.warn(
    `  Largest: "${biggest.text}" ×${biggest.count} (${formatTime(biggest.fromSec)}–${formatTime(biggest.toSec)}). Try a larger --whisper-model (e.g. large-v3) for that section.`
  );
}

export function normalizeWord(word: string): string {
  return word
    .toLowerCase()
    .replace(/[^a-z0-9']/g, "") // strip punctuation except apostrophes
    .trim();
}

function parseTokens(output: WhisperOutput, fillerWords: Set<string>): Token[] {
  const tokens: Token[] = [];

  const { segments, collapsed } = collapseRepeatedSegments(
    output.transcription
  );
  warnOnCollapsedRuns(collapsed);

  for (const segment of segments) {
    for (const t of segment.tokens ?? []) {
      const leadingSpace = /^\s/.test(t.text);
      const word = t.text.trim();
      if (!word) continue;
      if (SPECIAL_TOKEN_RE.test(word)) continue; // skip [_BEG_] etc.

      const normalized = normalizeWord(word);
      if (!normalized) continue; // skip punctuation-only tokens

      tokens.push({
        word,
        normalized,
        start: t.offsets.from / 1000,
        end: t.offsets.to / 1000,
        isFiller: fillerWords.has(normalized),
        leadingSpace,
      });
    }
  }

  return tokens;
}

// ---------------------------------------------------------------------------
// Main transcribe functions
// ---------------------------------------------------------------------------

/**
 * Load word tokens from an existing whisper JSON transcript file.
 */
export async function loadTokensFromTranscript(
  transcriptPath: string,
  fillerWords: Set<string>
): Promise<Token[]> {
  if (!existsSync(transcriptPath)) {
    throw new Error(`Transcript file not found: ${transcriptPath}`);
  }
  const raw = await readFile(transcriptPath, "utf8");
  const output: WhisperOutput = JSON.parse(raw);
  const fillers = fillerWords.size > 0 ? fillerWords : FILLER_DEFAULTS;
  return parseTokens(output, fillers);
}

/**
 * Transcribe from a pre-extracted mono 16 kHz WAV file.
 * The caller is responsible for the WAV file's lifetime.
 */
export async function transcribeFromAudio(
  wavPath: string,
  config: Pick<RetakeConfig, 'model' | 'saveTranscriptPath' | 'fillerWords'>
): Promise<Token[]> {
  const fillerWords = config.fillerWords.size > 0
    ? config.fillerWords
    : FILLER_DEFAULTS;

  const whisperBin = await assertWhisperAvailable();
  const modelPath = resolveModelPath(config.model);
  const dtwSize = extractModelSize(modelPath, config.model);

  const outDir = await mkdtemp(join(tmpdir(), "quietcut-whisper-"));
  const outBase = join(outDir, "audio");

  try {
    const args = [
      "-m", modelPath,
      "-f", wavPath,
      "-oj",
      "-ojf",
      "-of", outBase,
      "-nfa",
      "--dtw", dtwSize,
      "-l", "auto",
      // Disable cross-segment text conditioning. Carrying prior decoded text
      // forward is the main trigger for whisper.cpp hallucination loops (one
      // sentence repeating for minutes); -mc 0 makes each window decode fresh.
      "-mc", "0",
      "-np",
    ];

    const result = await execa(whisperBin, args, { reject: false });

    const jsonPath = `${outBase}.json`;
    if (!existsSync(jsonPath)) {
      const stderrSnippet = (result.stderr ?? "").slice(0, 1000);
      throw new Error(
        `whisper did not produce output JSON.\n` +
          `Binary:    ${whisperBin}\n` +
          `Model:     ${modelPath}\n` +
          `DTW size:  ${dtwSize}\n` +
          `Exit code: ${result.exitCode ?? "(undefined — binary may not have run)"}\n` +
          `stderr:\n${stderrSnippet || "(empty)"}`
      );
    }

    const raw = await readFile(jsonPath, "utf8");
    const output: WhisperOutput = JSON.parse(raw);

    if (config.saveTranscriptPath) {
      await writeFile(config.saveTranscriptPath, raw, "utf8");
    }

    return parseTokens(output, fillerWords);
  } finally {
    await rm(outDir, { recursive: true, force: true });
  }
}

/**
 * Transcribe the input file and return word-level tokens.
 *
 * Uses whisper.cpp with --dtw <modelsize> and -nfa (no flash attention) to get
 * per-token timestamps. Flash attention must be disabled because whisper.cpp
 * silently drops DTW when flash attention is active.
 *
 * If config.transcriptPath points to an existing JSON file it is loaded
 * directly (no whisper run). If config.saveTranscriptPath is set the raw
 * whisper JSON is written there after transcribing.
 */
export async function transcribe(config: RetakeConfig): Promise<Token[]> {
  const fillerWords = config.fillerWords.size > 0
    ? config.fillerWords
    : FILLER_DEFAULTS;

  // --- Re-use existing transcript ---
  if (config.transcriptPath) {
    if (!existsSync(config.transcriptPath)) {
      throw new Error(`Transcript file not found: ${config.transcriptPath}`);
    }
    const raw = await readFile(config.transcriptPath, "utf8");
    const output: WhisperOutput = JSON.parse(raw);
    return parseTokens(output, fillerWords);
  }

  // --- Extract audio then transcribe; clean up WAV after ---
  const { wavPath, cleanup } = await extractAudio(config.input);
  try {
    return await transcribeFromAudio(wavPath, config);
  } finally {
    await cleanup();
  }
}

// ---------------------------------------------------------------------------
// Model path resolution
// ---------------------------------------------------------------------------

/**
 * Resolve a model name/shorthand to an absolute path whisper.cpp can load.
 *
 * Checks common install locations. If none match, returns the raw value and
 * lets whisper-cli produce its own error.
 */
function resolveModelPath(model: string): string {
  // Already an explicit path
  if (model.startsWith("/") || model.startsWith("./") || model.startsWith("../")) {
    return model;
  }

  const home = process.env.HOME ?? "";

  // Build a list of filenames to try, in preference order.
  // "base.en" -> try ["ggml-base.en.bin", "ggml-base.bin"] so that a
  // multilingual base model is used as a fallback when the .en variant
  // isn't installed.
  const filenames = buildFilenames(model);

  const searchDirs = [
    // Homebrew whisper-cpp (macOS, Intel + Apple Silicon)
    `/opt/homebrew/share/whisper-cpp/models`,
    `/usr/local/share/whisper-cpp/models`,
    // Versioned Cellar paths enumerated at runtime
    ...globHomebrewDirs(),
    // macOS app support dirs (Elgato VoiceSync, SuperWhisper, etc.)
    `${home}/Library/Application Support/elgato/VoiceSync/Model`,
    `${home}/Library/Application Support/superwhisper`,
    `${home}/Library/Application Support/superwhisper/models`,
    // XDG / Linux
    `${home}/.local/share/whisper/models`,
    `/usr/share/whisper/models`,
    // whisper.cpp source tree
    `${home}/whisper.cpp/models`,
    // CWD models/
    `models`,
  ];

  for (const filename of filenames) {
    for (const dir of searchDirs) {
      const p = `${dir}/${filename}`;
      if (existsSync(p)) return p;
    }
  }

  return model; // fall back to raw name — whisper-cli will report the error
}

/**
 * Build the ordered list of ggml filenames to search for a given model spec.
 * "base.en"  -> ["ggml-base.en.bin", "ggml-base.bin"]
 * "small"    -> ["ggml-small.bin"]
 * "large-v3" -> ["ggml-large-v3.bin"]
 */
function buildFilenames(model: string): string[] {
  // If already a full filename, use as-is
  if (model.endsWith(".bin")) return [model];

  const withPrefix = model.startsWith("ggml-") ? model : `ggml-${model}`;
  const primary = `${withPrefix}.bin`;
  const results = [primary];

  // If the model has a language suffix (.en, .multilingual), also try without it
  const withoutLang = withPrefix.replace(/\.(en|multilingual)$/, "");
  if (withoutLang !== withPrefix) {
    results.push(`${withoutLang}.bin`);
  }

  return results;
}

/**
 * Enumerate versioned Homebrew Cellar model directories for whisper-cpp.
 * e.g. /opt/homebrew/Cellar/whisper-cpp/1.8.4/share/whisper-cpp/models
 */
function globHomebrewDirs(): string[] {
  const bases = [
    "/opt/homebrew/Cellar/whisper-cpp",
    "/usr/local/Cellar/whisper-cpp",
  ];
  const results: string[] = [];
  for (const base of bases) {
    if (!existsSync(base)) continue;
    try {
      const { readdirSync } = require("node:fs") as typeof import("node:fs");
      for (const version of readdirSync(base)) {
        results.push(`${base}/${version}/share/whisper-cpp/models`);
      }
    } catch {
      // ignore
    }
  }
  return results;
}

// ---------------------------------------------------------------------------
// DTW model size inference
// ---------------------------------------------------------------------------

/**
 * Derive the --dtw alignment preset from the model path or config name.
 *
 * whisper.cpp's --dtw presets are: tiny, tiny.en, base, base.en, small,
 * small.en, medium, medium.en, large.v1, large.v2, large.v3. Note the large
 * variants use DOTS (large.v3), while model FILENAMES use hyphens
 * (ggml-large-v3.bin) — so we must translate. Passing the hyphenated form makes
 * whisper-cli abort with "unknown DTW preset".
 *
 * Examples:
 *   "ggml-base.en.bin"  -> "base"
 *   "ggml-small.bin"    -> "small"
 *   "ggml-large-v3.bin" -> "large.v3"
 *   "large-v2"          -> "large.v2"
 *   "base.en"           -> "base"
 */
export function extractModelSize(resolvedPath: string, configModel: string): string {
  const source = resolvedPath !== configModel ? resolvedPath : configModel;
  const name = source.split("/").pop() ?? source; // basename

  // Strip "ggml-" prefix and ".bin" suffix
  const stripped = name.replace(/^ggml-/, "").replace(/\.bin$/, "");

  // Map "base.en" -> "base", "small.en" -> "small"
  let size = stripped.replace(/\.(en|multilingual)$/, "");

  // Translate large filename forms to whisper.cpp DTW preset names.
  if (/^large-v[123]$/.test(size)) {
    size = size.replace("large-v", "large.v"); // large-v3 -> large.v3
  } else if (size === "large") {
    size = "large.v3"; // bare "large" -> newest preset
  }

  const known = [
    "tiny", "base", "small", "medium",
    "large.v1", "large.v2", "large.v3",
  ];
  if (known.includes(size)) return size;

  // Fallback: return whatever we stripped — whisper-cli will validate
  return size || "base";
}
