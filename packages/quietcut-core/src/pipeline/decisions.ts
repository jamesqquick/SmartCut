/**
 * Decision values pushed back into the `runSmartcut` async generator
 * in response to a `retakeProposed` event.
 *
 * - `remove`       — apply this retake cut
 * - `keep`         — skip this proposal, keep the recording as-is
 * - `approveRest`  — apply this and every remaining proposal
 * - `cancel`       — abort the pipeline; no output is produced
 */
export type RetakeDecision =
  | { kind: "remove" }
  | { kind: "keep" }
  | { kind: "approveRest" }
  | { kind: "cancel" };
