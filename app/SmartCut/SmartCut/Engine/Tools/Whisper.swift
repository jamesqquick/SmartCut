import Foundation

// MARK: - Whisper

/// whisper-cli discovery, model resolution, and DTW preset mapping.
/// Ports quietcut-core/src/utils/whisper.ts + retake/transcribe.ts (path bits).
enum Whisper {

    static let candidates = ["whisper-cli", "whisper"]

    // MARK: - Discovery

    /// Find the first whisper CLI binary available on PATH.
    static func findCli(runner: ProcessRunner) async -> String? {
        for bin in candidates {
            if let _ = await runner.resolve(bin) { return bin }
        }
        return nil
    }

    static func assertAvailable(runner: ProcessRunner) async throws -> String {
        guard let bin = await findCli(runner: runner) else {
            throw EngineError.toolNotFound(
                "whisper-cli (tried: \(candidates.joined(separator: ", "))). " +
                "Install: brew install whisper-cpp"
            )
        }
        return bin
    }

    // MARK: - Model path resolution

    /// Resolve a model name/shorthand to an absolute path whisper.cpp can load.
    static func resolveModelPath(_ model: String) -> String {
        // Already an explicit path.
        if model.hasPrefix("/") || model.hasPrefix("./") || model.hasPrefix("../") {
            return model
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        let filenames = buildFilenames(model)
        let searchDirs: [String] = [
            "/opt/homebrew/share/whisper-cpp/models",
            "/usr/local/share/whisper-cpp/models",
        ] + globHomebrewDirs() + [
            "\(home)/Library/Application Support/elgato/VoiceSync/Model",
            "\(home)/Library/Application Support/superwhisper",
            "\(home)/Library/Application Support/superwhisper/models",
            "\(home)/.local/share/whisper/models",
            "/usr/share/whisper/models",
            "\(home)/whisper.cpp/models",
            "models",
        ]
        for filename in filenames {
            for dir in searchDirs {
                let path = dir + "/" + filename
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        return model
    }

    private static func buildFilenames(_ model: String) -> [String] {
        if model.hasSuffix(".bin") { return [model] }
        let withPrefix = model.hasPrefix("ggml-") ? model : "ggml-\(model)"
        let primary = withPrefix + ".bin"
        var results = [primary]
        // Also try without language suffix (.en, .multilingual) as fallback.
        let withoutLang = withPrefix
            .replacingOccurrences(of: #"\.(en|multilingual)$"#,
                                  with: "", options: .regularExpression)
        if withoutLang != withPrefix {
            results.append(withoutLang + ".bin")
        }
        return results
    }

    private static func globHomebrewDirs() -> [String] {
        let bases = ["/opt/homebrew/Cellar/whisper-cpp", "/usr/local/Cellar/whisper-cpp"]
        var results: [String] = []
        for base in bases {
            guard FileManager.default.fileExists(atPath: base),
                  let versions = try? FileManager.default.contentsOfDirectory(atPath: base)
            else { continue }
            for version in versions {
                results.append("\(base)/\(version)/share/whisper-cpp/models")
            }
        }
        return results
    }

    // MARK: - DTW preset

    /// Derive the --dtw alignment preset from the model path or config name.
    /// whisper.cpp presets: tiny, base, small, medium, large.v1, large.v2, large.v3
    static func extractModelSize(resolvedPath: String, configModel: String) -> String {
        let source = (resolvedPath != configModel) ? resolvedPath : configModel
        let name   = URL(fileURLWithPath: source).lastPathComponent

        // Strip "ggml-" prefix and ".bin" suffix.
        var size = name
            .replacingOccurrences(of: "^ggml-", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.bin$", with: "", options: .regularExpression)

        // Strip language suffix (.en, .multilingual).
        size = size.replacingOccurrences(of: #"\.(en|multilingual)$"#,
                                         with: "", options: .regularExpression)

        // Translate large filename forms: large-v3 → large.v3
        if size.range(of: #"^large-v[123]$"#, options: .regularExpression) != nil {
            size = size.replacingOccurrences(of: "large-v", with: "large.v")
        } else if size == "large" {
            size = "large.v3"
        }

        let known = ["tiny", "base", "small", "medium", "large.v1", "large.v2", "large.v3"]
        if known.contains(size) { return size }
        return size.isEmpty ? "base" : size
    }
}
