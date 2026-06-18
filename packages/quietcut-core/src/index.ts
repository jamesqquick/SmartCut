// Public API for quietcut-core.
// Phase 1.4 — the runSmartcut async generator is exported.

export { detectSilences } from "./detect.js";
export * from "./edit-plan.js";
export { createGatewayClient, resolveGatewayEnv } from "./llm/gateway.js";
export type {
  RetakeDecision,
  RetakeReviewResult,
  ReviewCutDecision,
} from "./pipeline/decisions.js";
export type {
  PipelineEvent,
  ReviewProposal,
  Stage,
} from "./pipeline/events.js";
export {
  applyReviewResult,
  buildReviewProposals,
  timeRangeToIndices,
  toTranscriptTokens,
} from "./pipeline/review-batch.js";
export { runSmartcut } from "./pipeline/runSmartcut.js";
export { planLlmRetakeOps } from "./planners/llm-retake-planner.js";
export {
  crfToVideoToolboxQuality,
  type ResolvedVideoEncoder,
  render,
} from "./render.js";
export {
  loadTokensFromTranscript,
  transcribeFromAudio,
} from "./retake/transcribe.js";
export * from "./segments.js";
export * from "./types.js";
export {
  assertFfmpegAvailable,
  detectVideoToolbox,
  extractAudio,
  getDuration,
} from "./utils/ffmpeg.js";
export {
  defaultSmartcutOutput,
  warnIfUnsupportedContainer,
} from "./utils/paths.js";
export { formatDuration, formatTime } from "./utils/time.js";
