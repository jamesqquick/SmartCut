import Foundation

// MARK: - ReviewBatch
// Ports quietcut-core/src/pipeline/review-batch.ts

let manualOpPrefix = "m-"

// MARK: - timeRangeToIndices

/// Map a time range [start, end) to the inclusive token indices whose midpoints fall inside.
/// Falls back to the nearest token when the range is in silence.
func timeRangeToIndices(_ tokens: [Token], start: Double, end: Double) -> (start: Int, end: Int) {
    var first = -1
    var last  = -1
    for (i, t) in tokens.enumerated() {
        let mid = (t.start + t.end) / 2.0
        if mid >= start && mid < end {
            if first == -1 { first = i }
            last = i
        }
    }
    if first != -1 { return (first, last) }

    // Fallback: nearest token to cut start.
    var nearest = 0
    var bestDist = Double.infinity
    for (i, t) in tokens.enumerated() {
        let dist = abs((t.start + t.end) / 2.0 - start)
        if dist < bestDist { bestDist = dist; nearest = i }
    }
    return (nearest, nearest)
}

// MARK: - buildReviewProposals

func buildReviewProposals(_ tokens: [Token], _ ops: [RemoveRetakeOp]) -> [ReviewProposal] {
    ops.enumerated().map { i, op in
        let (s, e) = timeRangeToIndices(tokens, start: op.start, end: op.end)
        return ReviewProposal(opId: "r-\(i)", op: op, removeStartIndex: s, removeEndIndex: e)
    }
}

// MARK: - toTranscriptTokens

func toTranscriptTokens(_ tokens: [Token]) -> [TranscriptToken] {
    tokens.map { TranscriptToken(word: $0.word, start: $0.start, end: $0.end) }
}

// MARK: - rangeBounds

private func rangeBounds(
    _ tokens: [Token],
    removeStartIndex: Int,
    removeEndIndex: Int
) -> (s: Int, e: Int, start: Double, end: Double) {
    let s = max(0, min(removeStartIndex, tokens.count - 1))
    let e = max(s, min(removeEndIndex,   tokens.count - 1))
    let start = tokens[s].start
    let end: Double = (e + 1 < tokens.count) ? tokens[e + 1].start : tokens[e].end
    return (s, e, start, end)
}

// MARK: - rebuildOpFromRange

private func rebuildOpFromRange(
    _ tokens: [Token],
    baseOp: RemoveRetakeOp,
    removeStartIndex: Int,
    removeEndIndex: Int
) -> RemoveRetakeOp? {
    let (s, e, start, end) = rangeBounds(tokens, removeStartIndex: removeStartIndex, removeEndIndex: removeEndIndex)
    guard end > start else { return nil }
    return RemoveRetakeOp(
        type: "removeRetake",
        start: start, end: end,
        reason: baseOp.reason,
        removedText: reconstructText(tokens, from: s, to: e),
        keptText:    sentenceAfter(tokens, startIdx: e + 1),
        contextBefore: sentenceBefore(tokens, endIdx: s - 1),
        contextAfter:  baseOp.contextAfter,
        confidence: baseOp.confidence
    )
}

// MARK: - buildManualOp

func buildManualOp(_ tokens: [Token], removeStartIndex: Int, removeEndIndex: Int) -> RemoveRetakeOp? {
    let (s, e, start, end) = rangeBounds(tokens, removeStartIndex: removeStartIndex, removeEndIndex: removeEndIndex)
    guard end > start else { return nil }
    return RemoveRetakeOp(
        type: "removeRetake",
        start: start, end: end,
        reason: "Manual cut",
        removedText: reconstructText(tokens, from: s, to: e),
        keptText:    sentenceAfter(tokens, startIdx: e + 1),
        contextBefore: sentenceBefore(tokens, endIdx: s - 1),
        contextAfter:  sentenceAfter(tokens, startIdx: e + 1),
        confidence: 100
    )
}

// MARK: - applyReviewResult

func applyReviewResult(
    _ tokens: [Token],
    _ proposals: [ReviewProposal],
    _ cuts: [ReviewCutDecision]
) -> [RemoveRetakeOp] {
    let byId = Dictionary(uniqueKeysWithValues: proposals.map { ($0.opId, $0) })
    var result: [RemoveRetakeOp] = []

    for cut in cuts {
        guard cut.enabled else { continue }
        guard let proposal = byId[cut.opId] else {
            // Manual cut (m- prefix) — build from word range.
            if cut.opId.hasPrefix(manualOpPrefix) {
                if let manual = buildManualOp(tokens,
                    removeStartIndex: cut.removeStartIndex,
                    removeEndIndex:   cut.removeEndIndex) {
                    result.append(manual)
                }
            }
            continue
        }

        let unchanged = cut.removeStartIndex == proposal.removeStartIndex
                     && cut.removeEndIndex   == proposal.removeEndIndex
        if unchanged {
            result.append(proposal.op)
            continue
        }

        if let rebuilt = rebuildOpFromRange(tokens, baseOp: proposal.op,
            removeStartIndex: cut.removeStartIndex,
            removeEndIndex:   cut.removeEndIndex) {
            result.append(rebuilt)
        }
    }

    return result.sorted { $0.start < $1.start }
}
