import Foundation

enum Formatters {
    /// Mirrors `formatDuration` in quietcut-core/utils/time.ts.
    /// Sub-minute → `Ns.NNNs`, otherwise `M:SS.NNN`.
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        if seconds < 60 {
            return String(format: "%.3fs", seconds)
        }
        let m = Int(seconds / 60)
        let s = seconds - Double(m) * 60
        return String(format: "%d:%06.3f", m, s)
    }

    /// Short variant used in chips: `12.4s` or `1m 23s`.
    static func shortDuration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let m = Int(seconds / 60)
        let s = Int(seconds.rounded()) - m * 60
        return "\(m)m \(s)s"
    }

    /// `HH:MM:SS.mmm`
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let h = Int(seconds / 3600)
        let m = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        let s = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s)
    }

    /// `412 MB` style.
    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    static func percent(_ value: Double, fractionDigits: Int = 1) -> String {
        String(format: "%.\(fractionDigits)f%%", max(0, min(100, value)))
    }
}
