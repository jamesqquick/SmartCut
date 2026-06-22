import Foundation

/// Domain errors for the native pipeline engine.
enum EngineError: Error, LocalizedError {
    case fileNotFound(String)
    case toolNotFound(String)
    case unexpectedOutput(String)
    case transcriptionFailed(String)
    case llmError(String)
    case renderFailed(String)
    case cancelled
    case noInputFile
    case missingCredentials(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "File not found: \(p)"
        case .toolNotFound(let t): return "\"\(t)\" not found on PATH. Make sure it is installed."
        case .unexpectedOutput(let m): return m
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        case .llmError(let m): return "LLM error: \(m)"
        case .renderFailed(let m): return "Render failed: \(m)"
        case .cancelled: return "Cancelled."
        case .noInputFile: return "No input file specified."
        case .missingCredentials(let m): return "Missing credentials: \(m)"
        }
    }
}
