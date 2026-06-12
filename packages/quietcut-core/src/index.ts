// Public API for quietcut-core.
// Phase 1.2 — initial export surface. The runSmartcut async generator
// and pipeline event types are added in Phase 1.3 / 1.4.

export * from "./types.js";
export * from "./edit-plan.js";
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
