import Foundation

// MARK: - planLlmRetakeOps
// Ports quietcut-core/src/planners/llm-retake-planner.ts

private func midpointInAnyCut(_ token: Token, cuts: [Segment]) -> Bool {
    let mid = (token.start + token.end) / 2
    return cuts.contains { mid >= $0.start && mid < $0.end }
}

private func overlapsAny(_ region: Segment, cuts: [Segment]) -> Bool {
    cuts.contains { region.start < $0.end && $0.start < region.end }
}

/// Detect retakes via the LLM, snap each cut region to silence boundaries,
/// and convert to RemoveRetakeOp operations.
///
/// Runs up to `passes` detection passes; each pass re-runs the LLM over only
/// the words that survived the previous passes.
func planLlmRetakeOps(
    client: GatewayClient,
    model: String,
    tokens: [Token],
    snapSilences: [Segment],
    maxRetakeRatio: Double = 15,
    passes: Int = 2
) async throws -> [RemoveRetakeOp] {
    var allOps: [RemoveRetakeOp] = []
    var cutRegions: [Segment]    = []
    var working = tokens
    var passesRun = 0

    for pass in 0..<max(1, passes) {
        guard !working.isEmpty else { break }
        passesRun += 1

        let retakes = try await detectRetakesLLM(
            client: client,
            model: model,
            rawTokens: working,
            maxRetakeRatio: maxRetakeRatio
        )
        guard !retakes.isEmpty else { break }

        for r in retakes {
            let snapped = snapRetakeCutRegion(r.cutRegion, silences: snapSilences)
            guard !overlapsAny(snapped, cuts: cutRegions) else { continue }
            allOps.append(RemoveRetakeOp(
                type: "removeRetake",
                start: snapped.start,
                end:   snapped.end,
                reason: r.reason,
                removedText: r.removedText,
                keptText:    r.keptText,
                contextBefore: r.contextBefore,
                contextAfter:  r.contextAfter,
                confidence: Double(r.confidence)
            ))
            cutRegions.append(Segment(start: snapped.start, end: snapped.end))
        }

        if pass + 1 < max(1, passes) {
            let before = working.count
            working = working.filter { !midpointInAnyCut($0, cuts: cutRegions) }
            if working.count == before { break }  // converged
        }
    }

    if passesRun > 1 {
        print("[retake] Ran \(passesRun) passes; \(allOps.count) total cut(s).")
    }
    return allOps.sorted { $0.start < $1.start }
}
