// Public API for quietcut-core.
// Phase 1.3 — pipeline event types are exported.
// The runSmartcut async generator is added in Phase 1.4.

export * from "./types.js";
export * from "./edit-plan.js";
export type { PipelineEvent, Stage } from "./pipeline/events.js";
export type { RetakeDecision } from "./pipeline/decisions.js";
export * from "./segments.js";
export { detectSilences } from "./detect.js";
export { render } from "./render.js";
export {
  transcribeFromAudio,
  loadTokensFromTranscript,
} from "./retake/transcribe.js";
export { planLlmRetakeOps } from "./planners/llm-retake-planner.js";
export { createGatewayClient, resolveGatewayEnv } from "./llm/gateway.js";
export {
  assertFfmpegAvailable,
  getDuration,
  extractAudio,
} from "./utils/ffmpeg.js";
