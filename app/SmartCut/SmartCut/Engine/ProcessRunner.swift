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

struct ProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

// MARK: - ProcessRunner

/// Async wrapper around Foundation.Process — the execa/shell-out replacement.
/// Runs binaries found on the supplied extra PATH dirs + system PATH.
actor ProcessRunner {

    // Directories prepended to PATH for every spawn (e.g. /opt/homebrew/bin).
    var extraPathDirs: [String] = []

    /// Build the child process environment: system env + prepended PATH dirs.
    private func childEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let prepend = extraPathDirs.joined(separator: ":")
        if !prepend.isEmpty {
            if let existing = env["PATH"], !existing.isEmpty {
                env["PATH"] = "\(prepend):\(existing)"
            } else {
                env["PATH"] = "\(prepend):/usr/bin:/bin"
            }
        }
        return env
    }

    /// Resolve a binary name to a full path by scanning PATH dirs.
    /// Returns nil if not found.
    func resolve(_ binary: String) -> String? {
        // If already absolute or relative path, check directly.
        if binary.contains("/") {
            return FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
        }
        let env = childEnv()
        let pathDirs = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        for dir in pathDirs {
            let full = dir + "/" + binary
            if FileManager.default.isExecutableFile(atPath: full) {
                return full
            }
        }
        return nil
    }

    /// Assert a binary is available; throws ProcessError.toolNotFound if not.
    func assertAvailable(_ binary: String) throws {
        guard resolve(binary) != nil else {
            throw ProcessError.toolNotFound(binary)
        }
    }

    // MARK: - Run

    /// Run a binary synchronously (async-compatible), capture stdout + stderr.
    /// Throws ProcessError.nonZeroExit on non-zero exit.
    func run(
        _ binary: String,
        args: [String],
        allowNonZero: Bool = false
    ) async throws -> ProcessResult {
        guard let binPath = resolve(binary) else {
            throw ProcessError.toolNotFound(binary)
        }

        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            p.executableURL = URL(fileURLWithPath: binPath)
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(
                buildPathEnv()
            ) { _, new in new }
            p.standardOutput = outPipe
            p.standardError = errPipe

            p.terminationHandler = { proc in
                let stdout = String(
                    data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let code = proc.terminationStatus
                if !allowNonZero && code != 0 {
                    cont.resume(throwing: ProcessError.nonZeroExit(code, stderr: stderr))
                } else {
                    cont.resume(returning: ProcessResult(stdout: stdout, stderr: stderr, exitCode: code))
                }
            }

            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Streaming (stderr lines)

    /// Run a binary, streaming stderr lines via an AsyncStream. Stdout is captured
    /// and returned in the completion handler. Used for silence detection (parse
    /// ffmpeg stderr) and render progress (parse ffmpeg stdout).
    func runStreaming(
        _ binary: String,
        args: [String],
        onStderrLine: @Sendable @escaping (String) -> Void,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> (stdout: String, exitCode: Int32) {
        guard let binPath = resolve(binary) else {
            throw ProcessError.toolNotFound(binary)
        }

        // Capture stdout line by line if handler supplied, otherwise buffer.
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            p.executableURL = URL(fileURLWithPath: binPath)
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(
                buildPathEnv()
            ) { _, new in new }
            p.standardOutput = outPipe
            p.standardError = errPipe

            var stdoutAccum = ""
            var stdoutLineBuffer = ""
            var stderrLineBuffer = ""

            // Drain stdout
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                guard let text = String(data: fh.availableData, encoding: .utf8),
                      !text.isEmpty else { return }
                stdoutAccum += text
                if let handler = onStdoutLine {
                    stdoutLineBuffer += text
                    let lines = stdoutLineBuffer.components(separatedBy: "\n")
                    stdoutLineBuffer = lines.last ?? ""
                    for line in lines.dropLast() {
                        handler(line)
                    }
                }
            }

            // Drain stderr line by line
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                guard let text = String(data: fh.availableData, encoding: .utf8),
                      !text.isEmpty else { return }
                stderrLineBuffer += text
                let lines = stderrLineBuffer.components(separatedBy: "\n")
                stderrLineBuffer = lines.last ?? ""
                for line in lines.dropLast() {
                    onStderrLine(line)
                }
            }

            p.terminationHandler = { proc in
                // Flush any remaining data
                if let text = String(
                    data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ), !text.isEmpty {
                    stdoutAccum += text
                    if let handler = onStdoutLine {
                        let leftover = stdoutLineBuffer + text
                        for line in leftover.components(separatedBy: "\n") where !line.isEmpty {
                            handler(line)
                        }
                    }
                }
                // Flush remaining stderr
                if let text = String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ), !text.isEmpty {
                    let leftover = stderrLineBuffer + text
                    for line in leftover.components(separatedBy: "\n") where !line.isEmpty {
                        onStderrLine(line)
                    }
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: (stdout: stdoutAccum, exitCode: proc.terminationStatus))
            }

            do {
                try p.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Tracked process (killable by cancel)

    /// Run a long-lived process (e.g. ffmpeg render), emitting progress from
    /// stdout lines. Returns a Process handle via `onProcess` so the caller can
    /// SIGKILL it on cancellation.
    func runTracked(
        _ binary: String,
        args: [String],
        onProcess: @escaping (Process) -> Void,
        onStdoutLine: @escaping (String) -> Void
    ) async throws -> Int32 {
        guard let binPath = resolve(binary) else {
            throw ProcessError.toolNotFound(binary)
        }

        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            p.executableURL = URL(fileURLWithPath: binPath)
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(
                buildPathEnv()
            ) { _, new in new }
            p.standardOutput = outPipe
            p.standardError = errPipe

            var lineBuffer = ""

            outPipe.fileHandleForReading.readabilityHandler = { fh in
                guard let text = String(data: fh.availableData, encoding: .utf8),
                      !text.isEmpty else { return }
                lineBuffer += text
                let lines = lineBuffer.components(separatedBy: "\n")
                lineBuffer = lines.last ?? ""
                for line in lines.dropLast() {
                    onStdoutLine(line)
                }
            }

            p.terminationHandler = { proc in
                outPipe.fileHandleForReading.readabilityHandler = nil
                // Flush remaining
                if let text = String(
                    data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ), !text.isEmpty {
                    let leftover = lineBuffer + text
                    for line in leftover.components(separatedBy: "\n") where !line.isEmpty {
                        onStdoutLine(line)
                    }
                }
                cont.resume(returning: proc.terminationStatus)
            }

            do {
                try p.run()
                onProcess(p)
            } catch {
                cont.resume(throwing: error)
            }
        }
    }

    // MARK: - Private helpers

    private func buildPathEnv() -> [String: String] {
        let prepend = extraPathDirs.joined(separator: ":")
        guard !prepend.isEmpty else { return [:] }
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return ["PATH": "\(prepend):\(existing)"]
    }
}
