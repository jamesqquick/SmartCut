import Foundation

// MARK: - Public payloads

struct VideoMetadata: Decodable, Sendable {
    let durationSec: Double
    let sizeBytes: Int
    let codec: String?
    let width: Int?
    let height: Int?
}

struct AudioClip: Decodable, Sendable {
    let path: String
    let durationSec: Double
}

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

// MARK: - Errors

enum SidecarError: Error, LocalizedError {
    case notRunning
    case alreadyRunning
    case spawnFailed(String)
    case rpc(code: Int, message: String)
    case decodingFailed(String)
    case exited(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Sidecar is not running."
        case .alreadyRunning: return "Sidecar is already running."
        case .spawnFailed(let reason): return "Could not launch sidecar: \(reason)"
        case .rpc(let code, let message): return "Sidecar error (\(code)): \(message)"
        case .decodingFailed(let detail): return "Could not decode sidecar reply: \(detail)"
        case .exited(let status, let stderr):
            return "Sidecar exited with status \(status). Last stderr:\n\(stderr)"
        }
    }
}

// MARK: - JSON-RPC wire shapes

private struct RpcRequest<P: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: P?
}

private struct EmptyParams: Encodable {}

private struct RpcEnvelope: Decodable {
    let id: Int?
    let result: AnyJSON?
    let error: RpcErrorBody?
    let method: String?
    let params: AnyJSON?
}

private struct RpcErrorBody: Decodable {
    let code: Int
    let message: String
}

/// Type-erased JSON value used to defer decoding of `result` / `params`
/// until the caller knows the expected shape.
struct AnyJSON: Decodable, Sendable {
    let raw: Data

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(JSONValue.self) {
            self.raw = try JSONEncoder().encode(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: single, debugDescription: "Could not capture JSON payload")
        }
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: raw)
    }
}

/// Tiny recursive JSON value used purely to capture-then-reencode arbitrary
/// payloads. Not the most efficient — fine for the protocol traffic we see.
private enum JSONValue: Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unrecognised JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Client

/// Owns the Node sidecar process and brokers JSON-RPC traffic over its
/// stdio pipes. All public APIs are MainActor so AppState can call them
/// without worrying about thread hopping.
@MainActor
final class SidecarClient {
    private let config: SidecarConfig
    private let onEvent: (PipelineEvent) -> Void
    private let onExit: ((Int32) -> Void)?

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var stdoutBuffer = Data()
    private var stderrTail = ""  // last ~64 KB so we can surface it on crash

    private var nextID = 1
    private var pending: [Int: CheckedContinuation<AnyJSON, Error>] = [:]

    init(
        config: SidecarConfig = .defaults(),
        onEvent: @escaping (PipelineEvent) -> Void,
        onExit: ((Int32) -> Void)? = nil
    ) {
        self.config = config
        self.onEvent = onEvent
        self.onExit = onExit
    }

    /// Last ~64 KB of stderr from the sidecar. Useful for surfacing
    /// context after an unexpected exit. Read by AppState when building
    /// the error banner.
    var stderrSnapshot: String { stderrTail }

    deinit {
        // Best-effort termination without hopping to MainActor; the process
        // is owned by self so this only runs after MainActor releases it.
        if let p = process, p.isRunning {
            p.terminate()
        }
    }

    // MARK: Lifecycle

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        if process?.isRunning == true { throw SidecarError.alreadyRunning }

        guard FileManager.default.isReadableFile(atPath: config.sidecarPath.path) else {
            throw SidecarError.spawnFailed(
                "Sidecar bundle not found at \(config.sidecarPath.path). Did you run `pnpm --filter quietcut-server build`?"
            )
        }

        let p = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        p.executableURL = config.nodePath
        if config.nodePath.lastPathComponent == "env" {
            p.arguments = ["node", config.sidecarPath.path]
        } else {
            p.arguments = [config.sidecarPath.path]
        }
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // Build the child env: inherit ours, prepend ffmpeg/whisper dirs
        // so shell-out commands resolve, then merge in extra env (creds).
        var env = ProcessInfo.processInfo.environment
        let prepend = config.extraPathDirs.joined(separator: ":")
        if !prepend.isEmpty {
            if let path = env["PATH"], !path.isEmpty {
                env["PATH"] = "\(prepend):\(path)"
            } else {
                env["PATH"] = "\(prepend):/usr/bin:/bin"
            }
        }
        for (k, v) in config.extraEnv { env[k] = v }
        p.environment = env

        // Wire async readers.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            // Hop to MainActor for state mutation + dispatch.
            Task { @MainActor [weak self] in
                self?.ingestStdout(data)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(data: data, encoding: .utf8) ?? ""
            Task { @MainActor [weak self] in
                self?.ingestStderr(text)
            }
        }

        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor [weak self] in
                self?.handleTermination(status: status)
            }
        }

        do {
            try p.run()
        } catch {
            throw SidecarError.spawnFailed(error.localizedDescription)
        }

        self.process = p
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
    }

    func ensureRunning() throws {
        if process?.isRunning != true {
            try start()
        }
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        // Close stdin so the server exits cleanly via its readline 'close'
        // path. Fall back to terminate if that doesn't take it down.
        try? stdinPipe?.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            Task { @MainActor [weak self] in
                if self?.process?.isRunning == true {
                    self?.process?.terminate()
                }
            }
        }
    }

    // MARK: Public RPC

    func ping() async throws -> Bool {
        struct PongResult: Decodable { let pong: Bool }
        let result: PongResult = try await request(method: "ping", params: EmptyParams())
        return result.pong
    }

    func getMetadata(path: URL) async throws -> VideoMetadata {
        struct P: Encodable { let path: String }
        return try await request(method: "getMetadata", params: P(path: path.path))
    }

    func extractClip(input: URL, startSec: Double, endSec: Double) async throws -> AudioClip {
        struct P: Encodable {
            let path: String
            let startSec: Double
            let endSec: Double
        }
        return try await request(
            method: "extractClip",
            params: P(path: input.path, startSec: startSec, endSec: endSec))
    }

    func extractStitchedClip(
        input: URL,
        removeStart: Double,
        removeEnd: Double,
        padSec: Double? = nil,
        tailSec: Double? = nil
    ) async throws -> AudioClip {
        struct P: Encodable {
            let path: String
            let removeStart: Double
            let removeEnd: Double
            let padSec: Double?
            let tailSec: Double?
        }
        return try await request(
            method: "extractStitchedClip",
            params: P(
                path: input.path,
                removeStart: removeStart,
                removeEnd: removeEnd,
                padSec: padSec,
                tailSec: tailSec
            )
        )
    }

    /// Request a faithful audio preview of a single cut boundary.
    ///
    /// The sidecar runs `planToKeepSegments` on the supplied cuts + silences,
    /// intersects the result with `[focusStart − padSec, focusEnd + tailSec]`,
    /// and stitches the surviving segments into a temp WAV that reflects exactly
    /// what the final render will sound like at that boundary.
    func extractEditedPreview(
        input: URL,
        duration: Double,
        focusStart: Double,
        focusEnd: Double,
        padSec: Double = 2.5,
        tailSec: Double = 2.5,
        leadInMs: Int = 300,
        tailOutMs: Int = 300,
        cuts: [Segment] = [],
        silences: [Segment] = []
    ) async throws -> AudioClip {
        struct P: Encodable {
            let path: String
            let duration: Double
            let focusStart: Double
            let focusEnd: Double
            let padSec: Double
            let tailSec: Double
            let leadInMs: Int
            let tailOutMs: Int
            let cuts: [Segment]
            let silences: [Segment]
        }
        return try await request(
            method: "extractEditedPreview",
            params: P(
                path: input.path,
                duration: duration,
                focusStart: focusStart,
                focusEnd: focusEnd,
                padSec: padSec,
                tailSec: tailSec,
                leadInMs: leadInMs,
                tailOutMs: tailOutMs,
                cuts: cuts,
                silences: silences
            )
        )
    }

    @discardableResult
    func start(input: URL, options: StartOptions) async throws -> String {
        struct P: Encodable {
            let input: String
            let options: StartOptions
        }
        struct R: Decodable { let jobId: String }
        let result: R = try await request(
            method: "start",
            params: P(input: input.path, options: options))
        return result.jobId
    }

    func decide(opId: String, action: RetakeDecision) async throws {
        struct P: Encodable {
            let opId: String
            let action: String
        }
        struct R: Decodable { let ok: Bool }
        let _: R = try await request(
            method: "decide", params: P(opId: opId, action: action.rawValue))
    }

    /// Submit the batch transcript-review result (the final, possibly adjusted,
    /// set of cuts) in response to a `reviewReady` event.
    func submitReview(cuts: [ReviewCutDecision]) async throws {
        struct P: Encodable {
            let cuts: [ReviewCutDecision]
        }
        struct R: Decodable { let ok: Bool }
        let _: R = try await request(method: "submitReview", params: P(cuts: cuts))
    }

    func cancel() async throws {
        struct R: Decodable {
            let ok: Bool
            let wasRunning: Bool
        }
        let _: R = try await request(method: "cancel", params: EmptyParams())
    }

    // MARK: - Plumbing

    private func request<P: Encodable, R: Decodable>(
        method: String, params: P
    ) async throws -> R {
        try ensureRunning()

        let id = nextID
        nextID += 1
        let req = RpcRequest(id: id, method: method, params: params)
        let data: Data
        do {
            data = try JSONEncoder().encode(req)
        } catch {
            throw SidecarError.decodingFailed(error.localizedDescription)
        }

        let json: AnyJSON = try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            do {
                try stdinPipe?.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
            } catch {
                pending.removeValue(forKey: id)
                cont.resume(throwing: SidecarError.spawnFailed(error.localizedDescription))
            }
        }

        do {
            return try json.decode(R.self)
        } catch {
            throw SidecarError.decodingFailed(
                "method=\(method): \(error.localizedDescription)")
        }
    }

    // MARK: stdout / stderr ingestion (MainActor)

    private func ingestStdout(_ data: Data) {
        stdoutBuffer.append(data)
        // Process complete lines (\n delimited).
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.prefix(upTo: nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            handleLine(Data(line))
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty else { return }
        let envelope: RpcEnvelope
        do {
            envelope = try JSONDecoder().decode(RpcEnvelope.self, from: data)
        } catch {
            stderrTail.append("\n[client] could not parse line: \(String(data: data, encoding: .utf8) ?? "?")")
            return
        }

        if let id = envelope.id {
            // Response to one of our requests.
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let err = envelope.error {
                cont.resume(throwing: SidecarError.rpc(code: err.code, message: err.message))
            } else if let result = envelope.result {
                cont.resume(returning: result)
            } else {
                cont.resume(throwing: SidecarError.decodingFailed(
                    "RPC response \(id) missing both result and error"))
            }
            return
        }

        // Notification.
        if envelope.method == "event", let params = envelope.params {
            do {
                let event = try params.decode(PipelineEvent.self)
                onEvent(event)
            } catch {
                stderrTail.append(
                    "\n[client] could not decode event: \(error.localizedDescription)")
            }
        }
    }

    private func ingestStderr(_ text: String) {
        stderrTail.append(text)
        // Cap at 64 KB so we don't grow forever during long runs.
        if stderrTail.count > 64 * 1024 {
            stderrTail = String(stderrTail.suffix(64 * 1024))
        }
    }

    private func handleTermination(status: Int32) {
        // Reject any still-pending requests.
        let leftovers = pending
        pending.removeAll()
        for (_, cont) in leftovers {
            cont.resume(throwing: SidecarError.exited(status: status, stderr: stderrTail))
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        onExit?(status)
    }
}
