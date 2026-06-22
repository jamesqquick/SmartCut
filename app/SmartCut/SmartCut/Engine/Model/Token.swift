import Foundation

// MARK: - Token
// Mirrors quietcut-core/src/types.ts Token.
// TranscriptToken + Segment are defined in Pipeline/PipelineEvent.swift.
// Token is engine-internal (not sent over the wire in v1).

struct Token: Sendable {
    let word: String          // original text from whisper
    let normalized: String    // lowercase, punctuation stripped (apostrophes kept)
    let start: Double         // seconds
    let end: Double           // seconds
    let isFiller: Bool
    /// True when whisper emitted this piece with a leading space — i.e. it begins
    /// a new word. False for sub-word continuations ("backs" in "roll"+"backs").
    let leadingSpace: Bool
}

// MARK: - Normalize

func normalizeWord(_ word: String) -> String {
    word.lowercased()
        .unicodeScalars
        .filter { scalar in
            // Keep a-z, 0-9, apostrophe
            let v = scalar.value
            return (v >= 0x61 && v <= 0x7A)   // a-z
                || (v >= 0x30 && v <= 0x39)   // 0-9
                || v == 0x27                  // apostrophe '
        }
        .reduce(into: "") { $0.append(Character($1)) }
        .trimmingCharacters(in: .whitespaces)
}

// MARK: - Default filler words

let defaultFillerWords: Set<String> = [
    "um", "uh", "like", "so", "okay", "ok", "right", "yeah",
    "uh-huh", "uhh", "umm", "hmm", "hm", "er", "err",
]
