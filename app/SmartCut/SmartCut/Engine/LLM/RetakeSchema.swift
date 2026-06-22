import Foundation

// MARK: - RetakeCut (tool input from the LLM)

struct RetakeCut: Sendable {
    let abandonedStartIndex: Int
    let keepStartIndex: Int
    let keepEndIndex: Int
    let reason: String
    let confidence: Int   // 0-100

    // MARK: - JSON decoding

    enum CodingKeys: String, CodingKey {
        case abandonedStartIndex, keepStartIndex, keepEndIndex, reason, confidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        abandonedStartIndex = try c.decode(Int.self, forKey: .abandonedStartIndex)
        keepStartIndex      = try c.decode(Int.self, forKey: .keepStartIndex)
        keepEndIndex        = try c.decode(Int.self, forKey: .keepEndIndex)
        reason              = try c.decode(String.self, forKey: .reason)
        let rawConf         = try c.decodeIfPresent(Double.self, forKey: .confidence)
        confidence          = rawConf.map { max(0, min(100, Int($0.rounded()))) } ?? 50
    }
}

extension RetakeCut: Decodable {}

struct RetakeToolInput: Decodable, Sendable {
    let cuts: [RetakeCut]
}

// MARK: - Validation error

struct RetakeValidationError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Validate (strict — drives repair retry)

/// Validate all index bounds and ordering invariants. Throws RetakeValidationError
/// with an LLM-readable message so the repair prompt can quote it.
func validateRetakeCuts(_ cuts: [RetakeCut], tokenCount: Int) throws {
    for (i, c) in cuts.enumerated() {
        for (label, idx) in [("abandonedStartIndex", c.abandonedStartIndex),
                              ("keepStartIndex",      c.keepStartIndex),
                              ("keepEndIndex",        c.keepEndIndex)] {
            guard idx >= 0 && idx < tokenCount else {
                throw RetakeValidationError(
                    message: "cuts[\(i)].\(label) (\(idx)) is out of range (max \(tokenCount - 1)).")
            }
        }
        guard c.abandonedStartIndex < c.keepStartIndex else {
            throw RetakeValidationError(
                message: "cuts[\(i)]: abandonedStartIndex (\(c.abandonedStartIndex)) must be < keepStartIndex (\(c.keepStartIndex)).")
        }
        guard c.keepStartIndex <= c.keepEndIndex else {
            throw RetakeValidationError(
                message: "cuts[\(i)]: keepStartIndex (\(c.keepStartIndex)) must be <= keepEndIndex (\(c.keepEndIndex)).")
        }
    }
    // Disjoint check.
    let sorted = cuts.sorted { $0.abandonedStartIndex < $1.abandonedStartIndex }
    for i in 1..<sorted.count {
        let prev = sorted[i - 1]
        let curr = sorted[i]
        guard curr.abandonedStartIndex > prev.keepEndIndex else {
            throw RetakeValidationError(
                message: "cuts overlap: a cut starting at \(curr.abandonedStartIndex) begins before the previous kept take ends at \(prev.keepEndIndex). Cuts must be disjoint.")
        }
    }
}

// MARK: - Sanitize (lenient — final safety net)

struct DroppedCut: Sendable {
    let reason: String
}

func sanitizeRetakeCuts(
    _ cuts: [RetakeCut],
    tokenCount: Int
) -> (cuts: [RetakeCut], dropped: [DroppedCut]) {
    var dropped: [DroppedCut] = []
    var cleaned: [RetakeCut] = []

    for original in cuts {
        // Clamp single off-by-one.
        var aIdx = original.abandonedStartIndex
        var kS   = original.keepStartIndex
        var kE   = original.keepEndIndex
        let conf = original.confidence

        if kE == tokenCount { kE = tokenCount - 1 }

        guard aIdx >= 0 && aIdx < tokenCount,
              kS  >= 0 && kS  < tokenCount,
              kE  >= 0 && kE  < tokenCount else {
            dropped.append(DroppedCut(
                reason: "index out of range (valid 0..\(tokenCount-1)): " +
                        "abandoned=\(aIdx), keepStart=\(kS), keepEnd=\(kE)"))
            continue
        }
        guard aIdx < kS else {
            dropped.append(DroppedCut(
                reason: "abandonedStartIndex (\(aIdx)) not before keepStartIndex (\(kS))"))
            continue
        }
        guard kS <= kE else {
            dropped.append(DroppedCut(
                reason: "keepStartIndex (\(kS)) after keepEndIndex (\(kE))"))
            continue
        }
        // Re-create with possibly clamped kE.
        cleaned.append(RetakeCut(
            abandonedStartIndex: aIdx, keepStartIndex: kS,
            keepEndIndex: kE, reason: original.reason, confidence: conf
        ))
    }

    // Greedy disjoint resolution.
    let sorted = cleaned.sorted { $0.abandonedStartIndex < $1.abandonedStartIndex }
    var disjoint: [RetakeCut] = []
    var lastKeepEnd = -1
    for c in sorted {
        guard c.abandonedStartIndex > lastKeepEnd else {
            dropped.append(DroppedCut(
                reason: "overlaps previous cut (starts at \(c.abandonedStartIndex), " +
                        "previous kept take ends at \(lastKeepEnd))"))
            continue
        }
        disjoint.append(c)
        lastKeepEnd = c.keepEndIndex
    }
    return (disjoint, dropped)
}

// Custom init for building RetakeCut programmatically (bypasses Decodable).
extension RetakeCut {
    init(abandonedStartIndex: Int, keepStartIndex: Int, keepEndIndex: Int,
         reason: String, confidence: Int) {
        self.abandonedStartIndex = abandonedStartIndex
        self.keepStartIndex      = keepStartIndex
        self.keepEndIndex        = keepEndIndex
        self.reason              = reason
        self.confidence          = confidence
    }
}
