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
    /// "auto" (hardware when available), "hardware" (VideoToolbox), or "software" (libx264).
    var encoder: String
    var crf: Int
    /// libx264 preset; ignored when the hardware encoder is used.
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
        encoder: "auto",
        crf: 18,
        preset: "veryfast",
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
        opts.encoder = encoder
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
        encoder = options.encoder
        crf = options.crf
        preset = options.preset
    }
}

extension AppPreferences {
    /// Tolerant decoding: any key missing from an older `preferences.json`
    /// falls back to the default value, so adding a new preference never
    /// invalidates the whole file and wipes a user's saved settings.
    ///
    /// Declared in an extension so the synthesized memberwise initializer
    /// (used by `.default`) is preserved.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppPreferences.default
        thresholdDb =
            try container.decodeIfPresent(Double.self, forKey: .thresholdDb)
            ?? fallback.thresholdDb
        minSilence =
            try container.decodeIfPresent(Double.self, forKey: .minSilence)
            ?? fallback.minSilence
        model =
            try container.decodeIfPresent(String.self, forKey: .model) ?? fallback.model
        passes =
            try container.decodeIfPresent(Int.self, forKey: .passes) ?? fallback.passes
        whisperModel =
            try container.decodeIfPresent(String.self, forKey: .whisperModel)
            ?? fallback.whisperModel
        leadInMs =
            try container.decodeIfPresent(Int.self, forKey: .leadInMs) ?? fallback.leadInMs
        tailOutMs =
            try container.decodeIfPresent(Int.self, forKey: .tailOutMs) ?? fallback.tailOutMs
        encoder =
            try container.decodeIfPresent(String.self, forKey: .encoder) ?? fallback.encoder
        crf = try container.decodeIfPresent(Int.self, forKey: .crf) ?? fallback.crf
        preset =
            try container.decodeIfPresent(String.self, forKey: .preset) ?? fallback.preset
        outputDirectory =
            try container.decodeIfPresent(String.self, forKey: .outputDirectory)
            ?? fallback.outputDirectory
    }
}
