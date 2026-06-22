import Foundation

// MARK: - Transcript text helpers (ports quietcut-core/src/retake/transcript-text.ts)

private let maxContextWords = 6
private let sentenceEndChars: Set<Character> = [".", "!", "?"]

/// Returns true when `word` ends a sentence (ends with . ! ? optionally followed by quote/bracket).
private func endsSentence(_ word: String) -> Bool {
    var s = word
    // Strip optional trailing quote/bracket.
    if let last = s.last, "\"')\"]".contains(last) { s = String(s.dropLast()) }
    return s.last.map { sentenceEndChars.contains($0) } ?? false
}

/// Join tokens[start...end] (inclusive) back into readable text.
func reconstructText(_ tokens: [Token], from start: Int, to end: Int) -> String {
    guard start >= 0, end < tokens.count, start <= end else { return "" }
    return tokens[start...end]
        .map(\.word)
        .joined(separator: " ")
        .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}

/// Collect the sentence ending at (and including) token `endIdx`.
func sentenceBefore(_ tokens: [Token], endIdx: Int) -> String {
    guard endIdx >= 0, endIdx < tokens.count else { return "" }
    var start = endIdx
    var count = 0
    while start > 0 && count < maxContextWords {
        if endsSentence(tokens[start - 1].word) { break }
        start -= 1
        count += 1
    }
    return reconstructText(tokens, from: start, to: endIdx)
}

/// Collect the sentence starting at token `startIdx`.
func sentenceAfter(_ tokens: [Token], startIdx: Int) -> String {
    guard startIdx >= 0, startIdx < tokens.count else { return "" }
    var end = startIdx
    var count = 0
    while end < tokens.count && count < maxContextWords {
        if endsSentence(tokens[end].word) { break }
        end += 1
        count += 1
    }
    end = min(end, tokens.count - 1)
    return reconstructText(tokens, from: startIdx, to: end)
}
