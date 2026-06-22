import Foundation

// MARK: - Snap (ports quietcut-core/src/retake/snap.ts)

private let snapWindowSeconds = 0.5

/// Snap a retake cut region's boundaries to nearby silence edges.
///
/// START → end of the nearest silence (containment-first, then ±0.5s window).
/// END   → CONSERVATIVELY: may snap earlier but never past the original end
///         (prevents clipping the first word of the kept take).
///
/// If snapping would invert the region, the original is returned unchanged.
func snapRetakeCutRegion(_ region: Segment, silences: [Segment]) -> Segment {
    let snappedStart = snapToSilenceEnd(region.start, silences: silences)
    // Clamp: end must not advance past the kept word's onset.
    let snappedEnd = min(region.end, snapToSilenceEnd(region.end, silences: silences))
    // Guard against inversion.
    if snappedEnd <= snappedStart {
        return region
    }
    return Segment(start: snappedStart, end: snappedEnd)
}

/// Snap `time` to the end of the nearest silence region (containment-first).
private func snapToSilenceEnd(_ time: Double, silences: [Segment]) -> Double {
    // 1. If the time falls inside a silence, snap to that silence's end.
    for s in silences {
        if time >= s.start && time <= s.end { return s.end }
    }
    // 2. Snap to the nearest silence end within the window.
    var best = time
    var bestDist = Double.infinity
    for s in silences {
        let dist = abs(s.end - time)
        if dist < bestDist && dist <= snapWindowSeconds {
            bestDist = dist
            best = s.end
        }
    }
    return best
}
