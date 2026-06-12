export type Segment = {
  start: number; // seconds
  end: number; // seconds
};

export type Config = {
  input: string;
  output: string;
  thresholdDb: number;
  minSilence: number; // seconds
  leadInMs: number; // milliseconds
  tailOutMs: number; // milliseconds
  skipApproval: boolean;
  dryRun: boolean;
  crf: number;
  preset: string;
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
  word: string;       // original text from whisper
  normalized: string; // lowercase, punctuation stripped
  start: number;      // seconds
  end: number;        // seconds
  isFiller: boolean;
  // True when whisper emitted this piece with a leading space, i.e. it begins a
  // new word. When false, the piece is a continuation of the previous token
  // (a sub-word fragment like "backs" in "roll"+"backs", or a contraction tail
  // like "'m"). Used by smartcut to reconstruct whole words; ignored elsewhere.
  leadingSpace?: boolean;
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
  minWords: number;          // default 3
  maxGapSeconds: number;     // default 3
  fillerWords: Set<string>;
  model: string;             // whisper model, default "base.en"
  transcriptPath?: string;   // reuse existing transcript JSON
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
  // shared render + padding params
  leadInMs: number;
  tailOutMs: number;
  skipApproval: boolean;
  dryRun: boolean;
  crf: number;
  preset: string;
};

export type CleanConfig = {
  input: string;
  output: string;
  // silence detection params
  thresholdDb: number;
  minSilence: number;       // seconds
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
