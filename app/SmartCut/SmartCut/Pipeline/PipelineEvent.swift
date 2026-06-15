import Foundation

// MARK: - Stage

/// Logical stages emitted by `runSmartcut`. Mirrors `Stage` in
/// `packages/quietcut-core/src/pipeline/events.ts`.
enum Stage: String, Codable, CaseIterable, Hashable, Sendable {
    case probe
    case extractAudio = "extract-audio"
    case silenceCoarse = "silence-coarse"
    case silenceFine = "silence-fine"
    case transcribe
    case detectRetakes = "detect-retakes"
    case review
    case render

    /// Human-readable label used in the sidebar + activity log.
    var displayName: String {
        switch self {
        case .probe: return "File loaded"
        case .extractAudio: return "Audio extracted"
        case .silenceCoarse: return "Silence detected"
        case .silenceFine: return "Fine silence pass"
        case .transcribe: return "Transcribed"
        case .detectRetakes: return "Retakes detected"
        case .review: return "Review"
        case .render: return "Rendered"
        }
    }
}

enum StageStatus: String, Codable, Hashable, Sendable {
    case start
    case done
    case fail
}

// MARK: - Sub-payload types

struct Segment: Codable, Hashable, Sendable {
    let start: Double
    let end: Double
}

/// One transcript word + timing. Mirrors `TranscriptToken` in `types.ts`.
/// `id` is the token's index in the transcript array (assigned on decode).
struct TranscriptToken: Codable, Hashable, Sendable {
    let word: String
    let start: Double
    let end: Double
}

/// One AI-suggested cut mapped to a transcript token range.
/// Mirrors `ReviewProposal` in `pipeline/events.ts`.
struct ReviewProposal: Codable, Hashable, Sendable {
    let opId: String
    let op: RemoveRetakeOp
    let removeStartIndex: Int
    let removeEndIndex: Int
}

/// Mirrors `RemoveRetakeOp` in `edit-plan.ts`.
struct RemoveRetakeOp: Codable, Hashable, Sendable {
    let type: String  // always "removeRetake"
    let start: Double
    let end: Double
    let reason: String
    let removedText: String
    let keptText: String
    let contextBefore: String
    let contextAfter: String
    let confidence: Double

    var duration: Double { end - start }
}

/// One operation in an `EditPlan`. Either a silence cut or a retake cut.
enum EditOperation: Codable, Hashable, Sendable {
    case removeSilence(start: Double, end: Double)
    case removeRetake(RemoveRetakeOp)

    private enum CodingKeys: String, CodingKey { case type, start, end }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "removeSilence":
            self = .removeSilence(
                start: try container.decode(Double.self, forKey: .start),
                end: try container.decode(Double.self, forKey: .end)
            )
        case "removeRetake":
            self = .removeRetake(try RemoveRetakeOp(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown EditOperation type: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .removeSilence(let start, let end):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("removeSilence", forKey: .type)
            try c.encode(start, forKey: .start)
            try c.encode(end, forKey: .end)
        case .removeRetake(let op):
            try op.encode(to: encoder)
        }
    }
}

struct EditPlan: Codable, Hashable, Sendable {
    let source: String
    let duration: Double
    let operations: [EditOperation]

    var silenceOperations: [EditOperation] {
        operations.filter {
            if case .removeSilence = $0 { return true } else { return false }
        }
    }

    var retakeOperations: [RemoveRetakeOp] {
        operations.compactMap {
            if case .removeRetake(let op) = $0 { return op } else { return nil }
        }
    }
}

// MARK: - PipelineEvent

/// Discriminated-union mirror of `PipelineEvent` in `events.ts`.
///
/// Decoding switches on the `type` field. Unknown event types decode as
/// `.unknown` rather than throwing — the protocol is allowed to grow.
enum PipelineEvent: Decodable, Hashable, Sendable {
    case stage(stage: Stage, status: StageStatus, message: String?, durationMs: Int?)
    case progress(stage: Stage, current: Int?, total: Int?, percent: Double?, note: String?)
    case metadata(durationSec: Double, sizeBytes: Int, codec: String?, width: Int?, height: Int?)
    case silenceFound(count: Int, segments: [Segment])
    case transcript(tokenCount: Int, preview: String)
    case reviewReady(total: Int, transcript: [TranscriptToken], proposals: [ReviewProposal])
    case retakeProposed(opId: String, op: RemoveRetakeOp, index: Int, total: Int)
    case retakeDecisionAck(opId: String, action: String)
    case renderProgress(frame: Int?, fps: Double?, speed: Double?, percent: Double?, etaSec: Double?)
    case done(plan: EditPlan, output: String, savedSec: Double, savedPercent: Double, elapsedSec: Double)
    case error(message: String, stage: Stage?, stack: String?)
    case unknown(type: String)

    private enum DiscKey: String, CodingKey { case type }

    private struct StagePayload: Decodable {
        let stage: Stage
        let status: StageStatus
        let message: String?
        let durationMs: Int?
    }

    private struct ProgressPayload: Decodable {
        let stage: Stage
        let current: Int?
        let total: Int?
        let percent: Double?
        let note: String?
    }

    private struct MetadataPayload: Decodable {
        let durationSec: Double
        let sizeBytes: Int
        let codec: String?
        let width: Int?
        let height: Int?
    }

    private struct SilenceFoundPayload: Decodable {
        let count: Int
        let segments: [Segment]
    }

    private struct TranscriptPayload: Decodable {
        let tokenCount: Int
        let preview: String
    }

    private struct ReviewReadyPayload: Decodable {
        let total: Int
        let transcript: [TranscriptToken]
        let proposals: [ReviewProposal]
    }

    private struct RetakeProposedPayload: Decodable {
        let opId: String
        let op: RemoveRetakeOp
        let index: Int
        let total: Int
    }

    private struct RetakeDecisionPayload: Decodable {
        let opId: String
        let action: String
    }

    private struct RenderProgressPayload: Decodable {
        let frame: Int?
        let fps: Double?
        let speed: Double?
        let percent: Double?
        let etaSec: Double?
    }

    private struct DonePayload: Decodable {
        let plan: EditPlan
        let output: String
        let savedSec: Double
        let savedPercent: Double
        let elapsedSec: Double
    }

    private struct ErrorPayload: Decodable {
        let message: String
        let stage: Stage?
        let stack: String?
    }

    init(from decoder: Decoder) throws {
        let disc = try decoder.container(keyedBy: DiscKey.self)
        let type = try disc.decode(String.self, forKey: .type)

        switch type {
        case "stage":
            let p = try StagePayload(from: decoder)
            self = .stage(stage: p.stage, status: p.status, message: p.message, durationMs: p.durationMs)
        case "progress":
            let p = try ProgressPayload(from: decoder)
            self = .progress(stage: p.stage, current: p.current, total: p.total, percent: p.percent, note: p.note)
        case "metadata":
            let p = try MetadataPayload(from: decoder)
            self = .metadata(durationSec: p.durationSec, sizeBytes: p.sizeBytes, codec: p.codec, width: p.width, height: p.height)
        case "silenceFound":
            let p = try SilenceFoundPayload(from: decoder)
            self = .silenceFound(count: p.count, segments: p.segments)
        case "transcript":
            let p = try TranscriptPayload(from: decoder)
            self = .transcript(tokenCount: p.tokenCount, preview: p.preview)
        case "reviewReady":
            let p = try ReviewReadyPayload(from: decoder)
            self = .reviewReady(total: p.total, transcript: p.transcript, proposals: p.proposals)
        case "retakeProposed":
            let p = try RetakeProposedPayload(from: decoder)
            self = .retakeProposed(opId: p.opId, op: p.op, index: p.index, total: p.total)
        case "retakeDecision":
            let p = try RetakeDecisionPayload(from: decoder)
            self = .retakeDecisionAck(opId: p.opId, action: p.action)
        case "renderProgress":
            let p = try RenderProgressPayload(from: decoder)
            self = .renderProgress(frame: p.frame, fps: p.fps, speed: p.speed, percent: p.percent, etaSec: p.etaSec)
        case "done":
            let p = try DonePayload(from: decoder)
            self = .done(plan: p.plan, output: p.output, savedSec: p.savedSec, savedPercent: p.savedPercent, elapsedSec: p.elapsedSec)
        case "error":
            let p = try ErrorPayload(from: decoder)
            self = .error(message: p.message, stage: p.stage, stack: p.stack)
        default:
            self = .unknown(type: type)
        }
    }
}
