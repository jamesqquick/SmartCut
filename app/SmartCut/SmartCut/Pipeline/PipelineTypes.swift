import Foundation

// MARK: - Types that the app uses when calling the pipeline engine.
// Previously defined in SidecarClient.swift alongside the RPC machinery;
// extracted here so they survive the sidecar deletion.

// MARK: - VideoMetadata

struct VideoMetadata: Decodable, Sendable {
    let durationSec: Double
    let sizeBytes: Int
    let codec: String?
    let width: Int?
    let height: Int?
}

// MARK: - AudioClip

// MARK: - VideoClip

/// A low-resolution mp4 preview clip produced by `extractEditedVideoPreview`.
struct VideoClip: Sendable {
    let path: String
    let durationSec: Double
}

struct AudioClip: Decodable, Sendable {
    let path: String
    let durationSec: Double
}

// MARK: - StartOptions

struct StartOptions: Encodable, Sendable {
    var output: String
    var thresholdDb: Double = -30
    var minSilence: Double = 0.6
    var model: String = "claude-opus-4-8"
    var maxRetakeRatio: Double = 15
    var passes: Int = 2
    var whisperModel: String = "base.en"
    var transcriptPath: String?
    var saveTranscriptPath: String?
    var planPath: String?
    var savePlanPath: String?
    var leadInMs: Int = 300
    var tailOutMs: Int = 300
    var skipApproval: Bool = false
    var dryRun: Bool = false
    var crf: Int = 18
    var preset: String = "medium"
}

// MARK: - TranscriptExportFormat

/// Transcript export formats, both aligned to the final edited timeline.
enum TranscriptExportFormat: String, Sendable {
    case aiJson = "ai-json"  // structured segments + words for AI editing
    case srt                 // YouTube SubRip caption track

    var fileExtension: String { self == .aiJson ? "json" : "srt" }
}

// MARK: - Engine errors surfaced to the UI

enum EngineUIError: Error, LocalizedError {
    case notConfigured
    case alreadyRunning
    case rpc(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:  return "Engine not configured."
        case .alreadyRunning: return "A job is already running."
        case .rpc(let m):     return m
        case .failed(let m):  return m
        }
    }
}
