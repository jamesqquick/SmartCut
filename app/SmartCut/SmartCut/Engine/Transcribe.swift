import Foundation

// MARK: - Whisper JSON wire types

private struct WhisperOutput: Decodable {
    var transcription: [WhisperSegment]

    struct WhisperSegment: Decodable {
        var text: String
        var tokens: [WhisperToken]?

        struct WhisperToken: Decodable {
            var text: String
            var offsets: Offsets
            struct Offsets: Decodable {
                var from: Int  // milliseconds
                var to: Int    // milliseconds
            }
        }
    }
}

// MARK: - Loop collapse

private let loopRunThreshold = 6

private struct CollapsedRun {
    let text: String
    let count: Int
    let fromSec: Double
    let toSec: Double
}

private func normalizeSegmentText(_ text: String) -> String {
    text.lowercased()
        .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

private func collapseRepeatedSegments(
    _ segments: [WhisperOutput.WhisperSegment]
) -> (segments: [WhisperOutput.WhisperSegment], collapsed: [CollapsedRun]) {
    var out: [WhisperOutput.WhisperSegment] = []
    var collapsed: [CollapsedRun] = []
    var i = 0
    while i < segments.count {
        let norm = normalizeSegmentText(segments[i].text)
        var j = i + 1
        while j < segments.count && !norm.isEmpty
                && normalizeSegmentText(segments[j].text) == norm {
            j += 1
        }
        let runLength = j - i
        if runLength >= loopRunThreshold {
            out.append(segments[i])
            let fromSec = Double(segments[i].tokens?.first?.offsets.from ?? 0) / 1000.0
            let toSec   = Double(segments[j-1].tokens?.last?.offsets.to ?? 0) / 1000.0
            collapsed.append(CollapsedRun(text: segments[i].text.trimmingCharacters(in: .whitespaces),
                                          count: runLength, fromSec: fromSec, toSec: toSec))
        } else {
            for k in i..<j { out.append(segments[k]) }
        }
        i = j
    }
    return (out, collapsed)
}

// MARK: - Token parsing

// Special tokens look like [_BEG_], [_TT_123], etc.
private func isSpecialToken(_ word: String) -> Bool {
    word.hasPrefix("[") && word.hasSuffix("]")
}

private func parseTokens(
    _ output: WhisperOutput,
    fillerWords: Set<String>
) -> [Token] {
    let (segments, collapsed) = collapseRepeatedSegments(output.transcription)
    if !collapsed.isEmpty {
        let biggest = collapsed.max(by: { $0.count < $1.count })!
        print("[whisper] Note: \(collapsed.count) repeated-line loop(s) collapsed. " +
              "Largest: \"\(biggest.text)\" ×\(biggest.count)")
    }

    var tokens: [Token] = []
    for segment in segments {
        for t in segment.tokens ?? [] {
            let leadingSpace = t.text.hasPrefix(" ")
            let word = t.text.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            guard !isSpecialToken(word) else { continue }  // skip [_BEG_] etc.
            let normalized = normalizeWord(word)
            guard !normalized.isEmpty else { continue }
            tokens.append(Token(
                word: word,
                normalized: normalized,
                start: Double(t.offsets.from) / 1000.0,
                end:   Double(t.offsets.to)   / 1000.0,
                isFiller: fillerWords.contains(normalized),
                leadingSpace: leadingSpace
            ))
        }
    }
    return tokens
}

// MARK: - Sub-word merge

/// Fold whisper sub-word pieces into whole words.
/// Pieces with leadingSpace==false are continuations of the previous token.
func mergeSubwordTokens(_ tokens: [Token]) -> [Token] {
    var merged: [Token] = []
    for t in tokens {
        let isContinuation = !t.leadingSpace && !merged.isEmpty
        if isContinuation {
            let head = merged[merged.count - 1]
            let combined = head.word + t.word
            merged[merged.count - 1] = Token(
                word: combined,
                normalized: normalizeWord(combined),
                start: head.start,
                end: t.end,
                isFiller: head.isFiller,
                leadingSpace: head.leadingSpace
            )
        } else {
            merged.append(t)
        }
    }
    return merged
}

// MARK: - Public transcribe functions

/// Load tokens from an existing whisper JSON file (skip the whisper run).
func loadTokensFromTranscript(_ path: String, fillerWords: Set<String> = []) throws -> [Token] {
    guard FileManager.default.fileExists(atPath: path) else {
        throw EngineError.transcriptionFailed("Transcript file not found: \(path)")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
    let fillers = fillerWords.isEmpty ? defaultFillerWords : fillerWords
    return parseTokens(output, fillerWords: fillers)
}

/// Transcribe from a pre-extracted mono 16 kHz WAV file.
func transcribeFromAudio(
    wavPath: String,
    whisperBin: String,
    model: String,
    saveTranscriptPath: String? = nil,
    fillerWords: Set<String> = [],
    runner: ProcessRunner
) async throws -> [Token] {
    let modelPath = Whisper.resolveModelPath(model)
    let dtwSize   = Whisper.extractModelSize(resolvedPath: modelPath, configModel: model)

    let tmpDir  = NSTemporaryDirectory() + "quietcut-whisper-\(UUID().uuidString)"
    let outBase = tmpDir + "/audio"
    try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: tmpDir) }

    let args: [String] = [
        "-m", modelPath,
        "-f", wavPath,
        "-oj",            // JSON output
        "-ojf",           // with word offsets
        "-of", outBase,
        "-nfa",           // no flash attention (required for DTW)
        "--dtw", dtwSize,
        "-l", "auto",
        "-mc", "0",       // disable cross-segment conditioning (reduces hallucination loops)
        "-np",            // no progress output
    ]

    let result = try await runner.run(whisperBin, args: args, allowNonZero: true)
    let jsonPath = outBase + ".json"
    guard FileManager.default.fileExists(atPath: jsonPath) else {
        let snippet = String(result.stderr.prefix(1000))
        throw EngineError.transcriptionFailed(
            "whisper did not produce output JSON.\n" +
            "Binary: \(whisperBin)\nModel: \(modelPath)\nDTW: \(dtwSize)\n" +
            "Exit: \(result.exitCode)\nstderr:\n\(snippet.isEmpty ? "(empty)" : snippet)"
        )
    }

    let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
    if let saveTranscriptPath {
        try data.write(to: URL(fileURLWithPath: saveTranscriptPath))
    }

    let output = try JSONDecoder().decode(WhisperOutput.self, from: data)
    let fillers = fillerWords.isEmpty ? defaultFillerWords : fillerWords
    return parseTokens(output, fillerWords: fillers)
}
