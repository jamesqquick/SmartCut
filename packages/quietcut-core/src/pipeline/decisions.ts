/**
 * Decision values pushed back into the `runSmartcut` async generator
 * in response to a `retakeProposed` event (per-cut review, used by the CLI).
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

/**
 * A single cut decision in the batch transcript-review flow. `removeStartIndex`
 * and `removeEndIndex` are inclusive token indices into the transcript that the
 * user wants removed; the client may have widened or narrowed them from the
 * AI's original proposal.
 */
export type ReviewCutDecision = {
  opId: string;
  enabled: boolean;
  removeStartIndex: number;
  removeEndIndex: number;
};

/**
 * The result of the batch transcript review (sent back in response to a
 * `reviewReady` event). Either the final per-cut decisions or a cancel.
 *
 * When the generator receives a plain `RetakeDecision` here instead (e.g. the
 * CLI auto-approving), `approveRest` means "apply all proposals unchanged" and
 * `cancel` aborts.
 */
export type RetakeReviewResult =
  | { kind: "review"; cuts: ReviewCutDecision[] }
  | { kind: "cancel" };
