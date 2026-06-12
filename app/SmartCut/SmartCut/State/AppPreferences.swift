import Foundation

/// Non-secret defaults that survive restarts. Lives at
/// `~/Library/Application Support/SmartCut/preferences.json`.
struct AppPreferences: Codable, Equatable, Sendable {
    var thresholdDb: Double
    var minSilence: Double
    var model: String
    var passes: Int
    var whisperModel: String
    var leadInMs: Int
    var tailOutMs: Int
    var crf: Int
    var preset: String
    /// Directory where the default output file lands. Empty = next to input.
    var outputDirectory: String?

    static let `default` = AppPreferences(
        thresholdDb: -30,
        minSilence: 0.6,
        model: "claude-opus-4-8",
        passes: 2,
        whisperModel: "base.en",
        leadInMs: 300,
        tailOutMs: 300,
        crf: 18,
        preset: "medium",
        outputDirectory: nil
    )

    // MARK: Persistence

    /// `~/Library/Application Support/SmartCut/preferences.json`
    static var fileURL: URL {
        let dir =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
                .appendingPathComponent("SmartCut", isDirectory: true))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/SmartCut")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("preferences.json")
    }

    static func load() -> AppPreferences {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else {
            return .default
        }
        return (try? JSONDecoder().decode(AppPreferences.self, from: data)) ?? .default
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.fileURL, options: [.atomic])
    }

    // MARK: Seeding StartOptions

    /// Build a fresh `StartOptions` for a new run, using these defaults.
    /// `output` is filled separately from the input URL.
    func makeStartOptions() -> StartOptions {
        var opts = StartOptions(output: "")
        opts.thresholdDb = thresholdDb
        opts.minSilence = minSilence
        opts.model = model
        opts.passes = passes
        opts.whisperModel = whisperModel
        opts.leadInMs = leadInMs
        opts.tailOutMs = tailOutMs
        opts.crf = crf
        opts.preset = preset
        return opts
    }

    /// Update these defaults from the most recent `StartOptions` snapshot
    /// (writes everything except the per-job `output`).
    mutating func update(from options: StartOptions) {
        thresholdDb = options.thresholdDb
        minSilence = options.minSilence
        model = options.model
        passes = options.passes
        whisperModel = options.whisperModel
        leadInMs = options.leadInMs
        tailOutMs = options.tailOutMs
        crf = options.crf
        preset = options.preset
    }
}
