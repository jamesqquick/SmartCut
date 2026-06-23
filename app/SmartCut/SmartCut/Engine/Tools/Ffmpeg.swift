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
                if let t = silenceTimestamp(from: line, key: "silence_start") {
                    currentStart = t
                } else if let t = silenceTimestamp(from: line, key: "silence_end"),
                          let start = currentStart {
                    silences.append(Segment(start: start, end: t))
                    currentStart = nil
                }
            }
        )

        // File ends in silence — close open segment at duration.
        if let start = currentStart {
            silences.append(Segment(start: start, end: duration))
        }
        return silences
    }

    // MARK: - Silence timestamp parsing

    /// Extract a floating-point timestamp following `key:` in an ffmpeg silencedetect line.
    ///
    /// ffmpeg emits lines like:
    ///   [silencedetect @ 0x...] silence_start: 1.23456
    ///   [silencedetect @ 0x...] silence_end: 5.678 | silence_duration: 4.444
    ///
    /// The previous approach split on CharacterSet.decimalDigits.inverted which treats the
    /// decimal point as a separator — "1.234" → "1" — truncating every boundary to the
    /// nearest whole second. This version walks past the key and reads the first token.
    private static func silenceTimestamp(from line: String, key: String) -> Double? {
        // Fast reject: key must appear in the line.
        guard let keyRange = line.range(of: key) else { return nil }
        // Everything after the key, e.g. ": 1.23456 | ..."
        let suffix = line[keyRange.upperBound...]
        // Skip the colon and any whitespace.
        let valueStart = suffix.drop(while: { $0 == ":" || $0 == " " })
        // Take digits and the decimal point until the first non-numeric character.
        var token = ""
        for ch in valueStart {
            if ch.isNumber || ch == "." { token.append(ch) }
            else if token.isEmpty { continue }  // leading non-numeric (shouldn't happen)
            else { break }
        }
        return token.isEmpty ? nil : Double(token)
    }

    // MARK: - VideoToolbox capability probe

    /// Cached result of the hardware-encoder probe. Initialised at most once per
    /// process; subsequent calls await the same Task and pay no spawn overhead.
    nonisolated(unsafe) private static var videoToolboxProbeTask: Task<Bool, Never>?

    /// Returns `true` if this ffmpeg build can encode H.264 with VideoToolbox
    /// in constant-quality (`-q:v`) mode.
    ///
    /// We do a one-frame encode to the null muxer rather than parsing
    /// `ffmpeg -encoders`: the codec appearing in that list does not guarantee
    /// that the host can initialise the VideoToolbox session or that `-q:v` is
    /// supported. Exit code 0 is the only trustworthy signal.
    ///
    /// The result is memoised for the process lifetime. Two concurrent first
    /// callers may race and each spawn a probe — both produce the same answer,
    /// so the last write wins and no data is corrupted.
    static func detectVideoToolbox(runner: ProcessRunner) async -> Bool {
        if let existing = videoToolboxProbeTask { return await existing.value }
        let task = Task<Bool, Never> {
            guard let result = try? await runner.run(
                "ffmpeg",
                args: [
                    "-hide_banner",
                    "-f", "lavfi",
                    "-i", "color=c=black:s=64x64:d=0.1:r=10",
                    "-frames:v", "1",
                    "-c:v", "h264_videotoolbox",
                    "-q:v", "60",
                    "-f", "null", "-",
                ],
                allowNonZero: true
            ) else { return false }
            return result.exitCode == 0
        }
        videoToolboxProbeTask = task
        return await task.value
    }

    // MARK: - CRF → VideoToolbox quality mapping

    /// Map an x264-style CRF (lower = better; UI range 12–30) onto a
    /// VideoToolbox constant-quality value (`-q:v`, higher = better; 1–100).
    ///
    /// VideoToolbox has no CRF. Its 1–100 scale is monotonic (higher q →
    /// higher bitrate/quality), so we map CRF [12,30] linearly onto [80,40].
    static func crfToVideoToolboxQuality(_ crf: Int) -> Int {
        let q = 80 - (crf - 12) * 40 / 18
        return max(1, min(100, q))
    }

    // MARK: - Render

    struct RenderProgress: Sendable {
        var frame: Int?
        var fps: Double?
        var speed: Double?
        var percent: Double?
        var etaSec: Double?
    }

    /// The encoder actually selected after resolving the `encoder` preference.
    enum ResolvedEncoder: String, Sendable {
        case hardware = "hardware"
        case software = "software"
    }

    /// Render output using trim/atrim+concat filter for frame-accurate cuts.
    /// Returns the spawned Process via `onProcess` so callers can kill it on cancel.
    ///
    /// `encoder` accepts `"auto"` (VideoToolbox when available, else libx264),
    /// `"hardware"` (VideoToolbox; throws if unavailable), or `"software"` (libx264).
    /// `onEncoder` is called once with the resolved encoder before ffmpeg starts,
    /// letting callers surface a progress note.
    static func render(
        input: String,
        output: String,
        keep: [Segment],
        encoder: String = "auto",
        crf: Int,
        preset: String,
        onProcess: @escaping @Sendable (Process) -> Void,
        onProgress: @escaping @Sendable (RenderProgress) -> Void,
        onEncoder: (@Sendable (ResolvedEncoder) -> Void)? = nil,
        runner: ProcessRunner
    ) async throws {
        // Resolve encoder preference → concrete encoder.
        let resolved: ResolvedEncoder
        switch encoder {
        case "software":
            resolved = .software
        case "hardware":
            let available = await detectVideoToolbox(runner: runner)
            guard available else {
                throw EngineError.unexpectedOutput(
                    "Hardware encoder (h264_videotoolbox) is not available in this ffmpeg build. "
                    + "Switch to Auto or Software in Settings → Output.")
            }
            resolved = .hardware
        default: // "auto" or unrecognised value
            resolved = await detectVideoToolbox(runner: runner) ? .hardware : .software
        }
        onEncoder?(resolved)

        // Build codec args for the resolved encoder.
        let codecArgs: [String]
        switch resolved {
        case .hardware:
            codecArgs = [
                "-c:v", "h264_videotoolbox",
                "-q:v", String(crfToVideoToolboxQuality(crf)),
                "-pix_fmt", "yuv420p",
            ]
        case .software:
            codecArgs = [
                "-c:v", "libx264",
                "-crf", String(crf),
                "-preset", preset,
                "-pix_fmt", "yuv420p",
            ]
        }

        let filter = buildTrimConcatFilter(keep)
        let totalKeptMs = keep.reduce(0.0) { $0 + ($1.end - $1.start) } * 1000.0

        let args: [String] = [
            "-hide_banner", "-y",
            "-i", input,
            "-filter_complex", filter,
            "-map", "[v]", "-map", "[a]",
        ] + codecArgs + [
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

    /// Faithful **video** preview of a cut boundary: same windowing +
    /// `planToKeepSegments` logic as `extractEditedPreview`, but outputs a
    /// 480p H.264/AAC mp4 suitable for playback in `VideoPreviewPlayer`.
    static func extractEditedVideoPreview(
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
    ) async throws -> VideoClip {
        guard focusEnd > focusStart else {
            throw EngineError.unexpectedOutput("extractEditedVideoPreview: focusEnd must be > focusStart")
        }

        let windowStart = max(0, focusStart - padSec)
        let windowEnd   = min(duration, focusEnd + tailSec)

        let operations: [EnginePlan.Op] =
            cuts.map { .retake(RemoveRetakeOp(
                type: "removeRetake", start: $0.start, end: $0.end,
                reason: "", removedText: "", keptText: "",
                contextBefore: "", contextAfter: "", confidence: 100)) } +
            silences.map { .silence(RemoveSilenceOp(start: $0.start, end: $0.end)) }

        let plan = buildEnginePlan(source: input, duration: duration, operations: operations)
        let keepAll = planToKeepSegments(plan, leadInMs: leadInMs, tailOutMs: tailOutMs)

        let windowed: [Segment] = keepAll.compactMap { seg in
            let s = max(seg.start, windowStart)
            let e = min(seg.end, windowEnd)
            return e - s > 1e-6 ? Segment(start: s, end: e) : nil
        }
        guard !windowed.isEmpty else {
            throw EngineError.unexpectedOutput(
                "The preview window is entirely removed by the current edit plan.")
        }

        // Build filter_complex: trim+scale video and trim audio per segment, then concat.
        let vParts = windowed.enumerated().map { i, seg in
            "[0:v]trim=start=\(seg.start):end=\(seg.end),setpts=PTS-STARTPTS,scale=-2:480[v\(i)]"
        }
        let aParts = windowed.enumerated().map { i, seg in
            "[0:a]atrim=start=\(seg.start):end=\(seg.end),asetpts=PTS-STARTPTS[a\(i)]"
        }
        let concatIn = windowed.indices.map { "[v\($0)][a\($0)]" }.joined()
        let filter = (vParts + aParts + ["\(concatIn)concat=n=\(windowed.count):v=1:a=1[vout][aout]"])
            .joined(separator: ";")

        let outPath = previewDir + "/" + UUID().uuidString + "-video-preview.mp4"
        let result = try await runner.run(
            "ffmpeg",
            args: [
                "-hide_banner", "-y",
                "-i", input,
                "-filter_complex", filter,
                "-map", "[vout]",
                "-map", "[aout]",
                "-c:v", "libx264", "-preset", "ultrafast", "-crf", "28",
                "-c:a", "aac",
                "-movflags", "+faststart",
                outPath,
            ],
            allowNonZero: true
        )
        guard result.exitCode == 0 else {
            throw EngineError.unexpectedOutput(
                "ffmpeg extractEditedVideoPreview failed (code \(result.exitCode)):\n\(result.stderr)")
        }
        scheduleCleanup(outPath)
        let clipDuration = windowed.reduce(0.0) { $0 + ($1.end - $1.start) }
        return VideoClip(path: outPath, durationSec: clipDuration)
    }
}
