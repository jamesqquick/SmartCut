import Foundation

// MARK: - Segment
// NOTE: Segment is defined in Pipeline/PipelineEvent.swift.
// This file adds pure math operations as extensions.

// MARK: - Segment math (ports quietcut-core/segments.ts)

extension Array where Element == Segment {

    /// Invert silence regions into keep regions across [0, duration].
    /// e.g. silences [2–5, 8–10] in a 12s file → keep [0–2, 5–8, 10–12]
    func invertToKeep(duration: Double) -> [Segment] {
        guard !isEmpty else { return [Segment(start: 0, end: duration)] }
        var keep: [Segment] = []
        var cursor = 0.0
        for silence in self {
            if cursor < silence.start {
                keep.append(Segment(start: cursor, end: silence.start))
            }
            cursor = silence.end
        }
        if cursor < duration {
            keep.append(Segment(start: cursor, end: duration))
        }
        return keep
    }

    /// Expand each segment by leadIn before and tailOut after, clamped to [0, duration].
    func applyPadding(leadInMs: Double, tailOutMs: Double, duration: Double) -> [Segment] {
        let leadIn = leadInMs / 1000.0
        let tailOut = tailOutMs / 1000.0
        return map { seg in
            Segment(
                start: Swift.max(0, seg.start - leadIn),
                end: Swift.min(duration, seg.end + tailOut)
            )
        }
    }

    /// Merge overlapping or adjacent segments into the fewest possible ranges.
    func mergingOverlaps() -> [Segment] {
        guard !isEmpty else { return [] }
        let sorted = sorted { $0.start < $1.start }
        var merged: [Segment] = [sorted[0]]
        for seg in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if seg.start <= last.end {
                merged[merged.count - 1] = Segment(start: last.start, end: Swift.max(last.end, seg.end))
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    /// Remove all regions in `others` from self, splitting/clipping as needed.
    func subtracting(_ others: [Segment]) -> [Segment] {
        guard !others.isEmpty else { return self }
        var result: [Segment] = []
        for seg in self {
            var current = seg
            for cut in others.sorted(by: { $0.start < $1.start }) {
                guard cut.end > current.start && cut.start < current.end else { continue }
                if cut.start > current.start {
                    result.append(Segment(start: current.start, end: cut.start))
                }
                current = Segment(start: cut.end, end: current.end)
                if current.start >= current.end { break }
            }
            if current.start < current.end {
                result.append(current)
            }
        }
        return result
    }

    /// Compute summary stats from a set of keep segments vs. original duration.
    func summarize(originalDuration: Double) -> (saved: Double, savedPercent: Double) {
        let keptDuration = reduce(0.0) { $0 + ($1.end - $1.start) }
        let saved = originalDuration - keptDuration
        let percent = originalDuration > 0 ? (saved / originalDuration) * 100.0 : 0.0
        return (saved: Swift.max(0, saved), savedPercent: Swift.max(0, percent))
    }
}
