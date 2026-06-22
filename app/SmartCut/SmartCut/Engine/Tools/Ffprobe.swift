import Foundation

// VideoMetadata is defined in Pipeline/PipelineTypes.swift.

// MARK: - Ffprobe

/// Reads metadata from media files via ffprobe.
enum Ffprobe {

    // MARK: - Wire types

    private struct ProbeOutput: Decodable {
        var format: ProbeFormat?
        var streams: [ProbeStream]?

        struct ProbeFormat: Decodable {
            var duration: String?
        }
        struct ProbeStream: Decodable {
            var codec_type: String?
            var codec_name: String?
            var width: Int?
            var height: Int?
        }
    }

    // MARK: - Public API

    /// Read metadata for a media file. Throws if the file is missing, ffprobe
    /// is unavailable, or the duration cannot be determined.
    static func metadata(
        for path: String,
        runner: ProcessRunner
    ) async throws -> VideoMetadata {
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngineError.fileNotFound(path)
        }

        let result = try await runner.run(
            "ffprobe",
            args: [
                "-v", "error",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                path,
            ]
        )

        let probe: ProbeOutput
        do {
            probe = try JSONDecoder().decode(ProbeOutput.self, from: Data(result.stdout.utf8))
        } catch {
            throw EngineError.unexpectedOutput(
                "ffprobe: could not parse JSON for \(path): \(error.localizedDescription)")
        }

        guard
            let durationStr = probe.format?.duration,
            let duration = Double(durationStr),
            duration.isFinite && duration > 0
        else {
            throw EngineError.unexpectedOutput(
                "ffprobe: could not determine duration of \(path)")
        }

        let sizeBytes = (try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? Int) ?? 0

        let videoStream = probe.streams?.first(where: { $0.codec_type == "video" })

        return VideoMetadata(
            durationSec: duration,
            sizeBytes: sizeBytes,
            codec: videoStream?.codec_name,
            width: videoStream?.width,
            height: videoStream?.height
        )
    }

    /// Get only the duration in seconds via ffprobe.
    static func duration(
        of path: String,
        runner: ProcessRunner
    ) async throws -> Double {
        let result = try await runner.run(
            "ffprobe",
            args: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                path,
            ]
        )
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let d = Double(trimmed), d.isFinite && d > 0 else {
            throw EngineError.unexpectedOutput(
                "ffprobe: could not determine duration of \(path) (got: \"\(trimmed)\")")
        }
        return d
    }
}
