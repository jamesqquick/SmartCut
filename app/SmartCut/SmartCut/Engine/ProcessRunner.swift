import Foundation

// MARK: - Errors

enum ProcessError: Error, LocalizedError {
    case toolNotFound(String)
    case nonZeroExit(Int32, stderr: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let bin):
            return "\"\(bin)\" not found on PATH. Make sure it is installed and accessible."
        case .nonZeroExit(let code, let stderr):
            let detail = stderr.isEmpty ? "" : "\n\(stderr)"
            return "Process exited with code \(code).\(detail)"
        case .cancelled:
            return "Process was cancelled."
        }
    }
}

// MARK: - Result types

struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

// MARK: - ProcessRunner

/// Async wrapper around Foundation.Process — the execa/shell-out replacement.
///
/// Design notes:
/// - `extraPathDirs` is supplied at init so there's no async race between setting
///   paths and the first `resolve()` call.
/// - All pipe state is serialised through a dedicated DispatchQueue to prevent
///   data races between `readabilityHandler` callbacks and `terminationHandler`.
/// - Every call wraps its Process in `withTaskCancellationHandler` so a cancelled
///   Swift Task kills the child process rather than leaving it orphaned.
actor ProcessRunner {

    let extraPathDirs: [String]

    init(extraPathDirs: [String] = []) {
        self.extraPathDirs = extraPathDirs
    }

    // MARK: - Path resolution

    /// Resolve a binary name to a full path using PATH + extra dirs.
    func resolve(_ binary: String) -> String? {
        if binary.contains("/") {
            return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
        }
        let pathStr = buildPathString()
        for dir in pathStr.split(separator: ":").map(String.init) {
            let full = dir + "/" + binary
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    func assertAvailable(_ binary: String) throws {
        guard resolve(binary) != nil else { throw ProcessError.toolNotFound(binary) }
    }

    // MARK: - run (capture stdout + stderr, check exit code)

    /// Run a binary and capture its output. Throws on non-zero exit unless `allowNonZero`.
    func run(
        _ binary: String,
        args: [String],
        allowNonZero: Bool = false
    ) async throws -> ProcessResult {
        guard let binPath = resolve(binary) else { throw ProcessError.toolNotFound(binary) }
        guard !Task.isCancelled else { throw ProcessError.cancelled }

        let p = makeProcess(binPath: binPath, args: args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe

        // Serialise all pipe mutations through one queue.
        let q = DispatchQueue(label: "ProcessRunner.run.\(binary)")
        var stdoutData = Data()
        var stderrData = Data()

        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { q.async { stdoutData.append(d) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { q.async { stderrData.append(d) } }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                p.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    // Drain any remaining bytes synchronously on q to prevent races.
                    q.sync {
                        stdoutData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                        stderrData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    let code   = proc.terminationStatus
                    if !allowNonZero && code != 0 {
                        cont.resume(throwing: ProcessError.nonZeroExit(code, stderr: stderr))
                    } else {
                        cont.resume(returning: ProcessResult(stdout: stdout, stderr: stderr, exitCode: code))
                    }
                }
                do { try p.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            p.terminate()
        }
    }

    // MARK: - runStreaming (line-by-line stderr + optional stdout)

    /// Run a binary, delivering stderr and optionally stdout line-by-line via callbacks.
    /// Returns accumulated stdout text and the exit code.
    func runStreaming(
        _ binary: String,
        args: [String],
        onStderrLine: @Sendable @escaping (String) -> Void,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> (stdout: String, exitCode: Int32) {
        guard let binPath = resolve(binary) else { throw ProcessError.toolNotFound(binary) }
        guard !Task.isCancelled else { throw ProcessError.cancelled }

        let p = makeProcess(binPath: binPath, args: args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe

        let q = DispatchQueue(label: "ProcessRunner.stream.\(binary)")
        var stdoutAccum = ""
        var stdoutBuf   = ""
        var stderrBuf   = ""

        outPipe.fileHandleForReading.readabilityHandler = { fh in
            guard let text = String(data: fh.availableData, encoding: .utf8), !text.isEmpty else { return }
            q.async {
                stdoutAccum += text
                if let handler = onStdoutLine {
                    stderrBuf = ""  // not used for stdout — use separate buffer
                    stdoutBuf += text
                    let lines = stdoutBuf.components(separatedBy: "\n")
                    stdoutBuf = lines.last ?? ""
                    lines.dropLast().forEach { handler($0) }
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { fh in
            guard let text = String(data: fh.availableData, encoding: .utf8), !text.isEmpty else { return }
            q.async {
                stderrBuf += text
                let lines = stderrBuf.components(separatedBy: "\n")
                stderrBuf = lines.last ?? ""
                lines.dropLast().forEach { onStderrLine($0) }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                p.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    q.sync {
                        // Flush remaining stdout
                        if let text = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                             encoding: .utf8), !text.isEmpty {
                            stdoutAccum += text
                            if let handler = onStdoutLine {
                                let leftover = stdoutBuf + text
                                leftover.components(separatedBy: "\n")
                                    .filter { !$0.isEmpty }
                                    .forEach { handler($0) }
                            }
                        }
                        // Flush remaining stderr
                        if let text = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                             encoding: .utf8), !text.isEmpty {
                            let leftover = stderrBuf + text
                            leftover.components(separatedBy: "\n")
                                .filter { !$0.isEmpty }
                                .forEach { onStderrLine($0) }
                        }
                    }
                    let result = q.sync { stdoutAccum }
                    cont.resume(returning: (stdout: result, exitCode: proc.terminationStatus))
                }
                do { try p.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            p.terminate()
        }
    }

    // MARK: - runTracked (long-lived process killable by caller)

    /// Run a long-lived process (e.g. ffmpeg render), delivering stdout line-by-line.
    /// The spawned Process is handed back via `onProcess` so the caller can kill it on cancel.
    func runTracked(
        _ binary: String,
        args: [String],
        onProcess: @escaping (Process) -> Void,
        onStdoutLine: @escaping (String) -> Void
    ) async throws -> Int32 {
        guard let binPath = resolve(binary) else { throw ProcessError.toolNotFound(binary) }
        guard !Task.isCancelled else { throw ProcessError.cancelled }

        let p = makeProcess(binPath: binPath, args: args)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError  = errPipe

        let q = DispatchQueue(label: "ProcessRunner.tracked.\(binary)")
        var lineBuf = ""

        outPipe.fileHandleForReading.readabilityHandler = { fh in
            guard let text = String(data: fh.availableData, encoding: .utf8), !text.isEmpty else { return }
            q.async {
                lineBuf += text
                let lines = lineBuf.components(separatedBy: "\n")
                lineBuf = lines.last ?? ""
                lines.dropLast().forEach { onStdoutLine($0) }
            }
        }

        // CRITICAL: drain stderr to prevent ffmpeg blocking on a full pipe buffer.
        // ffmpeg writes codec info / bitrate stats / warnings throughout every render.
        errPipe.fileHandleForReading.readabilityHandler = { fh in _ = fh.availableData }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                p.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    q.sync {
                        if let text = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                                             encoding: .utf8), !text.isEmpty {
                            let leftover = lineBuf + text
                            leftover.components(separatedBy: "\n")
                                .filter { !$0.isEmpty }
                                .forEach { onStdoutLine($0) }
                        }
                    }
                    cont.resume(returning: proc.terminationStatus)
                }
                do {
                    try p.run()
                    onProcess(p)
                } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            p.terminate()
        }
    }

    // MARK: - Helpers

    private func makeProcess(binPath: String, args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binPath)
        p.arguments     = args
        p.environment   = ProcessInfo.processInfo.environment.merging(
            ["PATH": buildPathString()]
        ) { _, new in new }
        return p
    }

    private func buildPathString() -> String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        guard !extraPathDirs.isEmpty else { return base }
        return extraPathDirs.joined(separator: ":") + ":" + base
    }
}
