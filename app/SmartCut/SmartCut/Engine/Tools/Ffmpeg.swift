import Foundation

// MARK: - Ffmpeg

/// ffmpeg/ffprobe shell-out helpers — audio extraction, silence detection,
/// render, and audio preview clips.
enum Ffmpeg {

    // MARK: - Availability

    static func assertAvailable(runner: ProcessRunner) async throws {
        for bin in ["ffmpeg", "ffprobe"] {
            guard await runner.resolve(bin) != nil else {
                throw EngineError.toolNotFound(bin)
            }
        }
    }

    // MARK: - Audio extraction

    struct ExtractedAudio: Sendable {
        let wavPath: String
        let tmpDir: String
        func cleanup() throws {
            try FileManager.default.removeItem(atPath: tmpDir)
        }
    }

    /// Extract mono 16 kHz PCM WAV into a temp directory.
    static func extractAudio(input: String, runner: ProcessRunner) async throws -> ExtractedAudio {
        let tmpDir = NSTemporaryDirectory().appending("quietcut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        let wavPath = tmpDir + "/audio.wav"

        let result = try await runner.run(
            "ffmpeg",
            args: [
                "-hide_banner", "-y",
                "-i", input,
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_s16le",
                wavPath,
            ],
            allowNonZero: true
        )
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(atPath: tmpDir)
            throw EngineError.unexpectedOutput(
                "ffmpeg audio extraction failed (code \(result.exitCode)):\n\(result.stderr)")
        }
        return ExtractedAudio(wavPath: wavPath, tmpDir: tmpDir)
    }

    // MARK: - Silence detection

    /// Run ffmpeg silencedetect and return parsed silence segments.
    static func detectSilences(
        input: String,
        thresholdDb: Double,
        minSilence: Double,
        duration: Double,
        runner: ProcessRunner
    ) async throws -> [Segment] {
        var silences: [Segment] = []
        var currentStart: Double? = nil

        _ = try await runner.runStreaming(
            "ffmpeg",
            args: [
                "-hide_banner", "-nostats",
                "-i", input,
                "-af", "silencedetect=noise=\(thresholdDb)dB:d=\(minSilence)",
                "-f", "null", "-",
            ],
            onStderrLine: { line in
                if let m = line.range(of: #"silence_start:\s*([\d.]+)"#, options: .regularExpression) {
                    let nums = line[m].components(separatedBy: CharacterSet.decimalDigits.inverted)
                        .filter { !$0.isEmpty }
                    if let d = nums.first.flatMap(Double.init) {
                        currentStart = d
                    }
                } else if let m = line.range(of: #"silence_end:\s*([\d.]+)"#, options: .regularExpression) {
                    let nums = line[m].components(separatedBy: CharacterSet.decimalDigits.inverted)
                        .filter { !$0.isEmpty }
                    if let d = nums.first.flatMap(Double.init), let start = currentStart {
                        silences.append(Segment(start: start, end: d))
                        currentStart = nil
                    }
                }
            }
        )

        // File ends in silence — close open segment at duration.
        if let start = currentStart {
            silences.append(Segment(start: start, end: duration))
        }
        return silences
    }

    // MARK: - Render

    struct RenderProgress: Sendable {
        var frame: Int?
        var fps: Double?
        var speed: Double?
        var percent: Double?
        var etaSec: Double?
    }

    /// Render output using trim/atrim+concat filter for frame-accurate cuts.
    /// Returns the spawned Process via `onProcess` so callers can kill it on cancel.
    static func render(
        input: String,
        output: String,
        keep: [Segment],
        crf: Int,
        preset: String,
        onProcess: @escaping @Sendable (Process) -> Void,
        onProgress: @escaping @Sendable (RenderProgress) -> Void,
        runner: ProcessRunner
    ) async throws {
        let filter = buildTrimConcatFilter(keep)
        let totalKeptMs = keep.reduce(0.0) { $0 + ($1.end - $1.start) } * 1000.0

        let args: [String] = [
            "-hide_banner", "-y",
            "-i", input,
            "-filter_complex", filter,
            "-map", "[v]", "-map", "[a]",
            "-c:v", "libx264",
            "-crf", String(crf),
            "-preset", preset,
            "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart",
            "-progress", "pipe:1",
            output,
        ]

        var progressBuffer = ""

        let code = try await runner.runTracked(
            "ffmpeg",
            args: args,
            onProcess: onProcess,
            onStdoutLine: { line in
                progressBuffer += line + "\n"
                // A progress block ends with "progress=continue" or "progress=end".
                if line.hasPrefix("progress=") {
                    if let p = parseProgressBlock(progressBuffer, totalKeptMs: totalKeptMs) {
                        onProgress(p)
                    }
                    progressBuffer = ""
                }
            }
        )
        guard code == 0 else {
            throw EngineError.renderFailed("ffmpeg exited with code \(code)")
        }
    }

    private static func parseProgressBlock(_ text: String, totalKeptMs: Double) -> RenderProgress? {
        var fields: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            let idx = line.firstIndex(of: "=") ?? line.endIndex
            if idx == line.endIndex { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = val
        }
        guard !fields.isEmpty else { return nil }

        var p = RenderProgress()
        if let v = fields["frame"].flatMap(Int.init)  { p.frame = v }
        if let v = fields["fps"].flatMap(Double.init), v > 0 { p.fps = v }
        if let s = fields["speed"], let m = s.range(of: #"([\d.]+)x"#, options: .regularExpression) {
            p.speed = Double(s[m].dropLast())
        }
        if let outMs = fields["out_time_ms"].flatMap(Double.init), totalKeptMs > 0 {
            let elapsedMs = outMs / 1000.0  // field is actually microseconds despite name
            p.percent = max(0, min(100, (elapsedMs / totalKeptMs) * 100.0))
            if let speed = p.speed, speed > 0 {
                let remaining = max(0, totalKeptMs - elapsedMs)
                p.etaSec = remaining / 1000.0 / speed
            }
        }
        return p
    }

    private static func buildTrimConcatFilter(_ segments: [Segment]) -> String {
        var parts: [String] = []
        var concatInputs: [String] = []
        for (i, seg) in segments.enumerated() {
            parts.append("[0:v]trim=start=\(seg.start):end=\(seg.end),setpts=PTS-STARTPTS[v\(i)]")
            parts.append("[0:a]atrim=start=\(seg.start):end=\(seg.end),asetpts=PTS-STARTPTS[a\(i)]")
            concatInputs.append("[v\(i)][a\(i)]")
        }
        parts.append("\(concatInputs.joined())concat=n=\(segments.count):v=1:a=1[v][a]")
        return parts.joined(separator: ";")
    }

    // MARK: - Audio preview clips

    private static let previewDir: String = {
        let dir = NSTemporaryDirectory() + "smartcut-previews"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func previewPath(suffix: String = "") -> String {
        previewDir + "/" + UUID().uuidString + suffix + ".wav"
    }

    private static func scheduleCleanup(_ path: String) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 300) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    struct AudioClip: Sendable {
        let path: String
        let durationSec: Double
    }

    /// Extract a simple WAV clip between startSec and endSec.
    static func extractClip(
        input: String,
        startSec: Double,
        endSec: Double,
        runner: ProcessRunner
    ) async throws -> AudioClip {
        guard endSec > startSec else {
            throw EngineError.unexpectedOutput("extractClip: endSec must be > startSec")
        }
        let outPath = previewPath(suffix: "-clip")
        let result = try await runner.run(
            "ffmpeg",
            args: [
                "-hide_banner", "-y",
                "-ss", String(startSec), "-to", String(endSec),
                "-i", input,
                "-vn", "-c:a", "pcm_s16le", "-ac", "1", "-ar", "44100",
                outPath,
            ],
            allowNonZero: true
        )
        guard result.exitCode == 0 else {
            throw EngineError.unexpectedOutput(
                "ffmpeg extractClip failed (code \(result.exitCode)):\n\(result.stderr)")
        }
        scheduleCleanup(outPath)
        return AudioClip(path: outPath, durationSec: endSec - startSec)
    }

    /// Render a stitched preview: audio before the cut joined to audio after.
    static func extractStitchedClip(
        input: String,
        removeStart: Double,
        removeEnd: Double,
        padSec: Double = 1.5,
        tailSec: Double = 4.0,
        runner: ProcessRunner
    ) async throws -> AudioClip {
        guard removeEnd > removeStart else {
            throw EngineError.unexpectedOutput("extractStitchedClip: removeEnd must be > removeStart")
        }
        let leadStart = max(0, removeStart - padSec)
        let leadEnd   = removeStart
        let tailStart = removeEnd
        let tailEnd   = removeEnd + tailSec

        let filter =
            "[0:a]atrim=start=\(leadStart):end=\(leadEnd),asetpts=PTS-STARTPTS[a0];" +
            "[0:a]atrim=start=\(tailStart):end=\(tailEnd),asetpts=PTS-STARTPTS[a1];" +
            "[a0][a1]concat=n=2:v=0:a=1[a]"

        let outPath = previewPath(suffix: "-stitch")
        let result = try await runner.run(
            "ffmpeg",
            args: [
                "-hide_banner", "-y",
                "-i", input,
                "-filter_complex", filter,
                "-map", "[a]",
                "-vn", "-c:a", "pcm_s16le", "-ac", "1", "-ar", "44100",
                outPath,
            ],
            allowNonZero: true
        )
        guard result.exitCode == 0 else {
            throw EngineError.unexpectedOutput(
                "ffmpeg extractStitchedClip failed (code \(result.exitCode)):\n\(result.stderr)")
        }
        scheduleCleanup(outPath)
        let duration = (leadEnd - leadStart) + (tailEnd - tailStart)
        return AudioClip(path: outPath, durationSec: duration)
    }

    /// Faithful edited preview: apply the full edit plan to a window around the cut.
    static func extractEditedPreview(
        input: String,
        duration: Double,
        focusStart: Double,
        focusEnd: Double,
        padSec: Double = 2.5,
        tailSec: Double = 2.5,
        leadInMs: Double = 300,
        tailOutMs: Double = 300,
        cuts: [Segment] = [],
        silences: [Segment] = [],
        runner: ProcessRunner
    ) async throws -> AudioClip {
        guard focusEnd > focusStart else {
            throw EngineError.unexpectedOutput("extractEditedPreview: focusEnd must be > focusStart")
        }

        let windowStart = max(0, focusStart - padSec)
        let windowEnd   = min(duration, focusEnd + tailSec)

        // Build a throwaway plan from supplied cuts + silences.
        let operations: [EnginePlan.Op] =
            cuts.map { .retake(RemoveRetakeOp(
                type: "removeRetake", start: $0.start, end: $0.end,
                reason: "", removedText: "", keptText: "",
                contextBefore: "", contextAfter: "", confidence: 100)) } +
            silences.map { .silence(RemoveSilenceOp(start: $0.start, end: $0.end)) }

        let plan = buildEnginePlan(source: input, duration: duration, operations: operations)
        let keepAll = planToKeepSegments(plan, leadInMs: leadInMs, tailOutMs: tailOutMs)

        // Intersect with the preview window.
        let windowed: [Segment] = keepAll.compactMap { seg in
            let s = max(seg.start, windowStart)
            let e = min(seg.end, windowEnd)
            return e - s > 1e-6 ? Segment(start: s, end: e) : nil
        }
        guard !windowed.isEmpty else {
            throw EngineError.unexpectedOutput(
                "The preview window is entirely removed by the current edit plan.")
        }

        let filterParts: [String] = windowed.enumerated().map { i, seg in
            "[0:a]atrim=start=\(seg.start):end=\(seg.end),asetpts=PTS-STARTPTS[a\(i)]"
        }
        let concatIn = windowed.indices.map { "[a\($0)]" }.joined()
        let filter = (filterParts + ["\(concatIn)concat=n=\(windowed.count):v=0:a=1[aout]"])
            .joined(separator: ";")

        let outPath = previewPath(suffix: "-edited")
        let result = try await runner.run(
            "ffmpeg",
            args: [
                "-hide_banner", "-y",
                "-i", input,
                "-filter_complex", filter,
                "-map", "[aout]",
                "-vn", "-c:a", "pcm_s16le", "-ac", "1", "-ar", "44100",
                outPath,
            ],
            allowNonZero: true
        )
        guard result.exitCode == 0 else {
            throw EngineError.unexpectedOutput(
                "ffmpeg extractEditedPreview failed (code \(result.exitCode)):\n\(result.stderr)")
        }
        scheduleCleanup(outPath)
        let clipDuration = windowed.reduce(0.0) { $0 + ($1.end - $1.start) }
        return AudioClip(path: outPath, durationSec: clipDuration)
    }
}
