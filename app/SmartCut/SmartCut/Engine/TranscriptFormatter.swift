import Foundation

// MARK: - TranscriptFormatter
//
// Swift implementations of the SRT and AI JSON transcript export formats.
// Both operate on a [TranscriptToken] array already on the final edited
// timeline (re-transcribed from the rendered output video).

enum TranscriptFormatter {

    // MARK: - SRT

    /// Render tokens as a SubRip (.srt) caption file for YouTube upload.
    /// Words are chunked into 1–2 line cues on sentence ends, pauses, and
    /// character budget — matching the TypeScript formatter in quietcut-core.
    static func srt(words: [TranscriptToken]) -> String {
        let cues = srtChunk(words: words)
        guard !cues.isEmpty else { return "" }
        var blocks: [String] = []
        for (i, cue) in cues.enumerated() {
            let range = "\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))"
            let lines = srtWrap(words: cue.words).joined(separator: "\n")
            blocks.append("\(i + 1)\n\(range)\n\(lines)")
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private struct SrtCue { let start: Double; let end: Double; let words: [String] }

    private static let maxCharsPerLine = 42
    private static let maxLines = 2
    private static let maxCueSec = 6.0
    private static let maxGapSec = 0.6
    private static let sentenceEnd = CharacterSet(charactersIn: ".!?")

    private static func srtChunk(words: [TranscriptToken]) -> [SrtCue] {
        var cues: [SrtCue] = []
        var current: [TranscriptToken] = []

        func flush() {
            guard !current.isEmpty else { return }
            cues.append(SrtCue(
                start: current.first!.start,
                end: current.last!.end,
                words: current.map(\.word)
            ))
            current = []
        }

        for word in words {
            let prev = current.last
            let gap = prev.map { word.start - $0.end } ?? 0
            let projectedChars = current.map(\.word).joined(separator: " ").count + 1 + word.word.count
            let projectedDur = current.first.map { word.end - $0.start } ?? 0
            let budget = maxCharsPerLine * maxLines

            if prev != nil && (gap > maxGapSec || projectedChars > budget || projectedDur > maxCueSec) {
                flush()
            }
            current.append(word)
            if word.word.unicodeScalars.last.map({ sentenceEnd.contains($0) }) == true {
                flush()
            }
        }
        flush()
        return cues
    }

    private static func srtWrap(words: [String]) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in words {
            let candidate = line.isEmpty ? word : "\(line) \(word)"
            if !line.isEmpty && candidate.count > maxCharsPerLine && lines.count < maxLines - 1 {
                lines.append(line)
                line = word
            } else {
                line = candidate
            }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    /// Format seconds as `HH:MM:SS,mmm` (SubRip timestamp).
    private static func srtTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let totalMs = Int((clamped * 1000).rounded())
        let ms = totalMs % 1000
        let totalSec = totalMs / 1000
        let s = totalSec % 60
        let m = (totalSec / 60) % 60
        let h = totalSec / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - AI JSON

    /// Render tokens as structured AI-editing JSON:
    /// `{ source, timeline, duration, segments, words }`
    static func aiJson(words: [TranscriptToken], source: String) -> String {
        let segments = groupSegments(words: words)
        let duration = words.last?.end ?? 0

        var out = "{\n"
        out += "  \"source\": \(jsonString(source)),\n"
        out += "  \"timeline\": \"edited\",\n"
        out += "  \"duration\": \(duration),\n"
        out += "  \"segments\": [\n"
        for (i, seg) in segments.enumerated() {
            let comma = i < segments.count - 1 ? "," : ""
            out += "    { \"id\": \(seg.id), \"start\": \(seg.start), \"end\": \(seg.end), \"text\": \(jsonString(seg.text)) }\(comma)\n"
        }
        out += "  ],\n"
        out += "  \"words\": [\n"
        for (i, word) in words.enumerated() {
            let comma = i < words.count - 1 ? "," : ""
            out += "    { \"word\": \(jsonString(word.word)), \"start\": \(word.start), \"end\": \(word.end) }\(comma)\n"
        }
        out += "  ]\n"
        out += "}\n"
        return out
    }

    // MARK: - Segmentation

    private struct Segment { let id: Int; let start: Double; let end: Double; let text: String }

    private static let maxGapSecSegment = 0.6
    private static let maxWordsPerSegment = 18

    private static func groupSegments(words: [TranscriptToken]) -> [Segment] {
        var segments: [Segment] = []
        var current: [TranscriptToken] = []
        var id = 0

        func flush() {
            guard !current.isEmpty else { return }
            segments.append(Segment(
                id: id,
                start: current.first!.start,
                end: current.last!.end,
                text: current.map(\.word).joined(separator: " ")
            ))
            id += 1
            current = []
        }

        for word in words {
            let prev = current.last
            let gap = prev.map { word.start - $0.end } ?? 0
            if prev != nil && gap > maxGapSecSegment { flush() }
            current.append(word)
            let endsSentence = word.word.unicodeScalars.last.map { sentenceEnd.contains($0) } == true
            if endsSentence || current.count >= maxWordsPerSegment { flush() }
        }
        flush()
        return segments
    }

    // MARK: - JSON helpers

    private static func jsonString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
