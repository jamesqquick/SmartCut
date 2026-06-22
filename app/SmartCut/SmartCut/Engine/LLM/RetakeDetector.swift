import Foundation

// MARK: - LlmRetake

struct LlmRetake: Sendable {
    let cutRegion: Segment      // unsnapped; planner snaps to silence
    let reason: String
    let removedText: String
    let keptText: String
    let contextBefore: String
    let contextAfter: String
    let confidence: Int         // 0-100
}

// MARK: - Constants

private let toolName = "report_retakes"
private let maxOutputTokens = 32_000
private let adaptiveThinkingModels: Set<String> = ["claude-opus-4-8"]

private let defaultMaxRetakeRatio: Double = 15
private let minSpanForDensityCheck: Double = 5
private let minRetakeWordDensity: Double   = 0.8
private let maxStreamRetries = 3

// MARK: - Confidence cap from delete/keep ratio

private func ratioConfidenceCap(_ ratio: Double) -> Int {
    if ratio <= 2  { return 100 }
    if ratio >= 12 { return 30  }
    return Int(100.0 - ((ratio - 2.0) / (12.0 - 2.0)) * 70.0)
}

// MARK: - Indexed transcript

private func buildIndexedTranscript(_ tokens: [Token]) -> String {
    tokens.enumerated().map { i, t in "[\(i)] \(t.word)" }.joined(separator: " ")
}

// MARK: - Abandoned-start refinement

/// Extend the cut backward to cover any exactly-repeated prefix.
private func refineAbandonedStart(
    tokens: [Token],
    modelStart: Int,
    keepStart: Int,
    keepEnd: Int
) -> Int {
    let maxL = min(keepStart, keepEnd - keepStart + 1)
    var best = keepStart  // no extension found
    for L in stride(from: maxL, through: 1, by: -1) {
        var matches = true
        for j in 0..<L {
            if tokens[keepStart - L + j].normalized != tokens[keepStart + j].normalized {
                matches = false
                break
            }
        }
        if matches {
            best = keepStart - L
            break
        }
    }
    return max(0, min(modelStart, best))
}

// MARK: - Tool JSON schema

private let retakeToolJsonSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "cuts": [
            "type": "array",
            "description": "Each detected retake. Everything from abandonedStartIndex up to (not including) keepStartIndex is deleted.",
            "items": [
                "type": "object",
                "properties": [
                    "abandonedStartIndex": ["type": "integer", "description": "Index of the FIRST word of the earlier attempt(s) to delete."],
                    "keepStartIndex":      ["type": "integer", "description": "Index of the FIRST word of the final take to keep. Must be greater than abandonedStartIndex."],
                    "keepEndIndex":        ["type": "integer", "description": "Index of the LAST word of the final take to keep. Must be >= keepStartIndex."],
                    "reason":              ["type": "string",  "description": "Short explanation of why this is a retake."],
                    "confidence":          ["type": "integer", "description": "Confidence 0-100 that this is a genuine re-recorded retake."],
                ] as [String: Any],
                "required": ["abandonedStartIndex", "keepStartIndex", "keepEndIndex", "reason", "confidence"],
            ] as [String: Any],
        ] as [String: Any],
    ] as [String: Any],
    "required": ["cuts"],
]

private let systemPrompt = """
You are a video editor's assistant. You are given a transcript of a single-speaker recording (a coding/tech tutorial) as a numbered list of word tokens. The speaker frequently re-records lines: they flub a sentence, pause, and say it again. Your job is to find every spot where the speaker re-recorded something and keep ONLY the latest (final) take.

For each retake, report:
- "abandonedStartIndex": the index of the FIRST word of the earlier attempt (the very first word of the first time they started saying it).
- "keepStartIndex": the index of the FIRST word of the final take you are keeping.
- "keepEndIndex": the index of the LAST word of that final take.
- "reason": a short explanation.
- "confidence": an integer 0–100 — how sure you are this is a genuine re-recorded retake.

How the cut works: EVERYTHING from abandonedStartIndex up to (but not including) keepStartIndex will be deleted.

A retake is LOCAL and SHORT: the redo comes IMMEDIATELY after the flubbed attempt — they stumble, pause for a moment, and say the same line again right away.

Critical rules:
- NEVER pair two occurrences that are far apart in the transcript.
- A single cut must not delete a large stretch of distinct content.
- Set abandonedStartIndex to the VERY FIRST word of the first attempt.
- The later take is always the keeper.
- For 3+ attempts of the same line in a row, set abandonedStartIndex at the FIRST attempt and keepStartIndex at the FINAL attempt.
- Cuts must be disjoint: each abandonedStartIndex must come after the previous cut's keepEndIndex.
- Do NOT flag intentional or rhetorical repetition.
- If there are no retakes, return an empty "cuts" array.
- Use the report_retakes tool to return your answer. Token indices only — never timestamps.
"""

// MARK: - Core detection

private func requestRawCuts(
    client: GatewayClient,
    model: String,
    messages: [[String: Any]]
) async throws -> [RetakeCut]? {
    let tools: [[String: Any]] = [[
        "name": toolName,
        "description": "Report every re-recorded take detected in the transcript so the earlier attempts can be cut.",
        "input_schema": retakeToolJsonSchema,
    ]]
    let useThinking = adaptiveThinkingModels.contains(model)

    let message = try await client.sendMessage(
        model: model,
        system: systemPrompt,
        messages: messages,
        tools: tools,
        maxTokens: maxOutputTokens,
        useAdaptiveThinking: useThinking
    )

    guard let toolInput = try message.toolInput(name: toolName, as: RetakeToolInput.self) else {
        return nil  // model didn't call the tool → treat as no retakes
    }
    return toolInput.cuts
}

// MARK: - detectRetakesLLM

/// Detect retakes contextually using Claude.
///
/// Expects **already-merged** (whole-word) tokens — sub-word pieces must be
/// folded before calling so token indices, timestamps, and the indexed transcript
/// all stay aligned. Call `mergeSubwordTokens` exactly once in the caller and
/// reuse the result for both the LLM detector and the review-screen proposals.
///
/// Ports quietcut-core/src/llm/detect-retakes-llm.ts detectRetakesLLM.
func detectRetakesLLM(
    client: GatewayClient,
    model: String,
    tokens: [Token],           // pre-merged whole-word tokens
    maxRetakeRatio: Double = defaultMaxRetakeRatio
) async throws -> [LlmRetake] {
    guard !tokens.isEmpty else { return [] }

    let transcript = buildIndexedTranscript(tokens)
    let userPrompt =
        "Here is the transcript as numbered word tokens (token count: \(tokens.count)).\n\n" +
        "\(transcript)\n\n" +
        "Find every re-recorded take and call report_retakes."

    var messages: [[String: Any]] = [["role": "user", "content": userPrompt]]

    // Attempt 1.
    var rawCuts: [RetakeCut]? = nil
    var firstError = ""
    do {
        rawCuts = try await requestRawCuts(client: client, model: model, messages: messages)
        if let cuts = rawCuts { try validateRetakeCuts(cuts, tokenCount: tokens.count) }
    } catch let e as RetakeValidationError {
        firstError = e.message
        rawCuts = nil
    }

    // Repair retry.
    if rawCuts == nil {
        let repairNote = firstError.isEmpty ? "" :
            "Your previous tool call was invalid: \(firstError)\n"
        messages.append([
            "role": "user",
            "content": repairNote +
                "You must call the report_retakes tool. Token indices must be within 0..\(tokens.count - 1), " +
                "with abandonedStartIndex < keepStartIndex <= keepEndIndex, and cuts must be disjoint. " +
                "If there are genuinely no retakes, call report_retakes with an empty \"cuts\" array.",
        ])
        do {
            rawCuts = try await requestRawCuts(client: client, model: model, messages: messages)
        } catch is RetakeValidationError {
            rawCuts = nil
        }
    }

    guard let cuts = rawCuts, !cuts.isEmpty else { return [] }

    let (sanitized, dropped) = sanitizeRetakeCuts(cuts, tokenCount: tokens.count)
    if !dropped.isEmpty {
        print("[retake] Note: dropped \(dropped.count) invalid cut(s):")
        for d in dropped { print("  - \(d.reason)") }
    }

    var retakes: [LlmRetake] = []
    var overlongDropped = 0
    var sparseDropped   = 0

    for c in sanitized {
        let abandonedStart = refineAbandonedStart(
            tokens: tokens,
            modelStart: c.abandonedStartIndex,
            keepStart: c.keepStartIndex,
            keepEnd: c.keepEndIndex
        )
        let start = tokens[abandonedStart].start
        let end   = tokens[c.keepStartIndex].start
        guard end > start else { continue }   // non-monotonic whisper timestamps

        let removedTokens = Double(c.keepStartIndex - abandonedStart)
        let keptTokens    = Double(c.keepEndIndex - c.keepStartIndex + 1)
        let ratio         = removedTokens / max(1.0, keptTokens)
        if ratio > maxRetakeRatio { overlongDropped += 1; continue }

        let span = end - start
        if span > minSpanForDensityCheck && removedTokens / span < minRetakeWordDensity {
            sparseDropped += 1; continue
        }

        let confidence = min(c.confidence, ratioConfidenceCap(ratio))

        retakes.append(LlmRetake(
            cutRegion: Segment(start: start, end: end),
            reason: c.reason,
            removedText: reconstructText(tokens, from: abandonedStart, to: c.keepStartIndex - 1),
            keptText:    reconstructText(tokens, from: c.keepStartIndex, to: c.keepEndIndex),
            contextBefore: sentenceBefore(tokens, endIdx: abandonedStart - 1),
            contextAfter:  sentenceAfter(tokens, startIdx: c.keepEndIndex + 1),
            confidence: confidence
        ))
    }

    if overlongDropped > 0 {
        print("[retake] Note: dropped \(overlongDropped) cut(s) with implausible delete-to-keep ratio (> \(maxRetakeRatio):1).")
    }
    if sparseDropped > 0 {
        print("[retake] Note: dropped \(sparseDropped) cut(s) with very low word density.")
    }

    return retakes
}
