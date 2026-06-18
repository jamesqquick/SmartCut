export type Segment = {
  start: number; // seconds
  end: number; // seconds
};

/**
 * Which video encoder the renderer uses for the export pass.
 * - "auto": prefer hardware (VideoToolbox) when available, else fall back to
 *   software (libx264). This is the default.
 * - "hardware": force VideoToolbox; the render fails fast with a clear error
 *   if the host ffmpeg can't encode H.264 with VideoToolbox.
 * - "software": always libx264 with the configured `preset`.
 */
export type VideoEncoder = "auto" | "hardware" | "software";

export type Config = {
  input: string;
  output: string;
  thresholdDb: number;
  minSilence: number; // seconds
  leadInMs: number; // milliseconds
  tailOutMs: number; // milliseconds
  skipApproval: boolean;
  dryRun: boolean;
  encoder: VideoEncoder;
  crf: number; // libx264 CRF; mapped to a VideoToolbox -q:v value for hardware
  preset: string; // libx264 preset; ignored by the hardware encoder
};

export type DetectionResult = {
  duration: number; // seconds
  silences: Segment[];
};

export type Summary = {
  originalDuration: number;
  newDuration: number;
  saved: number;
  savedPercent: number;
  cutCount: number;
};

// --- Retake types ---

export type Token = {
  word: string; // original text from whisper
  normalized: string; // lowercase, punctuation stripped
  start: number; // seconds
  end: number; // seconds
  isFiller: boolean;
  // True when whisper emitted this piece with a leading space, i.e. it begins a
  // new word. When false, the piece is a continuation of the previous token
  // (a sub-word fragment like "backs" in "roll"+"backs", or a contraction tail
  // like "'m"). Used by smartcut to reconstruct whole words; ignored elsewhere.
  leadingSpace?: boolean;
};

// A single transcript word sent to the review UI. A trimmed-down `Token`
// (whole word + timing) — no normalization/filler internals the client doesn't
// need. Indices into the `TranscriptToken[]` array are the unit of selection in
// the batch review screen.
export type TranscriptToken = {
  word: string; // whole word as displayed
  start: number; // seconds
  end: number; // seconds
};

export type RetakeMatch = {
  matchedPhrase: string;
  firstTake: { start: number; end: number; text: string };
  secondTake: { start: number; end: number; text: string };
  cutRegion: Segment; // snapped region to remove
};

export type RetakeConfig = {
  input: string;
  output: string;
  minWords: number; // default 3
  maxGapSeconds: number; // default 3
  fillerWords: Set<string>;
  model: string; // whisper model, default "base.en"
  transcriptPath?: string; // reuse existing transcript JSON
  saveTranscriptPath?: string;
  skipApproval: boolean;
  dryRun: boolean;
  crf: number;
  preset: string;
  leadInMs: number;
  tailOutMs: number;
};

export type SmartcutConfig = {
  input: string;
  output: string;
  // silence detection params
  thresholdDb: number;
  minSilence: number; // seconds
  // llm params
  model: string;
  fillerWords: Set<string>;
  maxRetakeRatio: number; // drop cuts whose delete/keep word ratio exceeds this
  passes: number; // retake detection passes (iterative self-correction)
  transcriptPath?: string;
  saveTranscriptPath?: string;
  planPath?: string; // load a saved EditPlan and skip detection
  savePlanPath?: string; // write the EditPlan JSON after detection
  // When true, surface all retakes at once with the full transcript via a
  // single `reviewReady` event and await a batch `RetakeReviewResult` (the
  // SwiftUI app's transcript-editing flow). When false/undefined, fall back to
  // the per-cut `retakeProposed` loop (the CLI).
  batchReview?: boolean;
  // shared render + padding params
  leadInMs: number;
  tailOutMs: number;
  skipApproval: boolean;
  dryRun: boolean;
  encoder: VideoEncoder;
  crf: number;
  preset: string;
};

export type CleanConfig = {
  input: string;
  output: string;
  // silence detection params
  thresholdDb: number;
  minSilence: number; // seconds
  // retake detection params
  minWords: number;
  maxGapSeconds: number;
  fillerWords: Set<string>;
  model: string;
  transcriptPath?: string;
  saveTranscriptPath?: string;
  // shared render + padding params
  leadInMs: number;
  tailOutMs: number;
  skipApproval: boolean;
  dryRun: boolean;
  crf: number;
  preset: string;
};
