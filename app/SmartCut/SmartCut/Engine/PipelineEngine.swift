import Foundation

// MARK: - PipelineEngine
// Drop-in replacement for SidecarClient. AppState calls the same public methods;
// the pipeline runs natively in Swift — no Node process involved.

@MainActor
final class PipelineEngine {

    // MARK: - Dependencies

    private let runner: ProcessRunner
    private var gatewayConfig: GatewayConfig?

    // MARK: - Job state

    private var activeTask: Task<Void, Never>?
    private var activeProcess: Process?
    /// Ring buffer of recent process stderr (mirrors sidecar stderrTail).
    private(set) var stderrSnapshot = ""

    // MARK: - Review gate (batch flow)

    private enum ReviewDecision {
        case submit([ReviewCutDecision])
        case cancel
    }
    private var reviewContinuation: CheckedContinuation<ReviewDecision, Never>?

    // MARK: - Callbacks

    private let onEvent: (PipelineEvent) -> Void
    private let onExit:  ((Int32) -> Void)?

    // MARK: - Init

    init(
        config: AppConfig,
        onEvent: @escaping (PipelineEvent) -> Void,
        onExit: ((Int32) -> Void)? = nil
    ) {
        self.onEvent = onEvent
        self.onExit  = onExit

        var paths: [String] = []
        if let dir = config.ffmpegDir, !dir.isEmpty { paths.append(dir) }
        for fallback in ["/opt/homebrew/bin", "/usr/local/bin"] where !paths.contains(fallback) {
            paths.append(fallback)
        }
        // Pass paths at init time — no async race with the first resolve() call.
        self.runner = ProcessRunner(extraPathDirs: paths)

        self.gatewayConfig = try? GatewayConfig.from(config)
    }

    // MARK: - Lifecycle (matches SidecarClient API)

    var isRunning: Bool { activeTask != nil }

    func stop() { cancelActive() }
    func terminateNow() { cancelActive() }

    private func cancelActive() {
        activeTask?.cancel()
        activeTask = nil
        killActiveProcess()
        reviewContinuation?.resume(returning: .cancel)
        reviewContinuation = nil
    }

    private func killActiveProcess() {
        guard let p = activeProcess, p.isRunning else { return }
        p.terminate()
        // Do not call waitUntilExit() — this is @MainActor-isolated and blocking
        // the main thread for even a brief SIGTERM drain would freeze the UI.
        // The OS reaps the child; execa-style signal-exit cleanup is not needed here.
        activeProcess = nil
    }

    // MARK: - Public RPC surface (mirrors SidecarClient)

    func getMetadata(path: URL) async throws -> VideoMetadata {
        try await Ffprobe.metadata(for: path.path, runner: runner)
    }

    func extractClip(input: URL, startSec: Double, endSec: Double) async throws -> AudioClip {
        let c = try await Ffmpeg.extractClip(
            input: input.path, startSec: startSec, endSec: endSec, runner: runner)
        return AudioClip(path: c.path, durationSec: c.durationSec)
    }

    func extractStitchedClip(
        input: URL,
        removeStart: Double, removeEnd: Double,
        padSec: Double? = nil, tailSec: Double? = nil
    ) async throws -> AudioClip {
        let c = try await Ffmpeg.extractStitchedClip(
            input: input.path,
            removeStart: removeStart, removeEnd: removeEnd,
            padSec: padSec ?? 1.5, tailSec: tailSec ?? 4.0,
            runner: runner)
        return AudioClip(path: c.path, durationSec: c.durationSec)
    }

    func extractEditedPreview(
        input: URL,
        duration: Double,
        focusStart: Double, focusEnd: Double,
        padSec: Double = 2.5, tailSec: Double = 2.5,
        leadInMs: Int = 300, tailOutMs: Int = 300,
        cuts: [Segment] = [],
        silences: [Segment] = []
    ) async throws -> AudioClip {
        let c = try await Ffmpeg.extractEditedPreview(
            input: input.path, duration: duration,
            focusStart: focusStart, focusEnd: focusEnd,
            padSec: padSec, tailSec: tailSec,
            leadInMs: Double(leadInMs), tailOutMs: Double(tailOutMs),
            cuts: cuts, silences: silences,
            runner: runner)
        return AudioClip(path: c.path, durationSec: c.durationSec)
    }

    @discardableResult
    func start(input: URL, options: StartOptions) async throws -> String {
        guard activeTask == nil else { return "current" }
        guard let gw = gatewayConfig else {
            throw EngineError.missingCredentials(
                "AI Gateway credentials not configured. Open Settings → Credentials.")
        }
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(input: input, options: options, gateway: gw)
        }
        return "current"
    }

    func decide(opId: String, action: RetakeDecision) async throws {
        // Legacy per-cut flow — not used by the app (batch mode). No-op.
    }

    func submitReview(cuts: [ReviewCutDecision]) async throws {
        reviewContinuation?.resume(returning: .submit(cuts))
        reviewContinuation = nil
    }

    func cancel() async throws {
        cancelActive()
    }

    // MARK: - Pipeline

    private func runPipeline(input: URL, options: StartOptions, gateway: GatewayConfig) async {
        let start = Date()

        // @Sendable closure safe to call from any thread (ffmpeg callbacks run off MainActor).
        let emitEvent: @Sendable (PipelineEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in self?.onEvent(event) }
        }

        // Stage helpers — these are @MainActor-isolated local functions that call emitEvent.
        func stageStart(_ s: Stage, _ msg: String? = nil) {
            emitEvent(.stage(stage: s, status: .start, message: msg, durationMs: nil))
        }
        func stageDone(_ s: Stage, _ msg: String? = nil, ms: Int? = nil) {
            emitEvent(.stage(stage: s, status: .done, message: msg, durationMs: ms))
        }
        func stageFail(_ s: Stage, _ msg: String) {
            emitEvent(.stage(stage: s, status: .fail, message: msg, durationMs: nil))
        }
        // Alias for convenience at non-stage emit sites.
        let emit = emitEvent

        defer {
            activeTask = nil
            killActiveProcess()
        }

        // --- Pre-flight ---
        guard FileManager.default.fileExists(atPath: input.path) else {
            emit(.error(message: "Input file not found: \(input.path)", stage: nil, stack: nil))
            return
        }

        // --- Probe ---
        stageStart(.probe, "Probing file…")
        let duration: Double
        do {
            duration = try await Ffprobe.duration(of: input.path, runner: runner)
            let size = (try? FileManager.default
                .attributesOfItem(atPath: input.path)[.size] as? Int) ?? 0
            emit(.metadata(durationSec: duration, sizeBytes: size, codec: nil, width: nil, height: nil))
            stageDone(.probe, "Duration: \(formatDuration(duration))")
        } catch {
            stageFail(.probe, "Could not read file duration.")
            emit(.error(message: error.localizedDescription, stage: .probe, stack: nil)); return
        }
        guard !Task.isCancelled else { return }

        // --- Audio extraction ---
        stageStart(.extractAudio, "Extracting audio…")
        let extracted: Ffmpeg.ExtractedAudio
        do {
            extracted = try await Ffmpeg.extractAudio(input: input.path, runner: runner)
            stageDone(.extractAudio, "Audio extracted.")
        } catch {
            stageFail(.extractAudio, "Audio extraction failed.")
            emit(.error(message: error.localizedDescription, stage: .extractAudio, stack: nil)); return
        }
        defer { try? extracted.cleanup() }
        guard !Task.isCancelled else { return }

        // --- Coarse silence ---
        stageStart(.silenceCoarse, "Detecting silence…")
        var silenceSegs: [Segment] = []
        do {
            silenceSegs = try await Ffmpeg.detectSilences(
                input: extracted.wavPath,
                thresholdDb: options.thresholdDb,
                minSilence: options.minSilence,
                duration: duration,
                runner: runner)
            emit(.silenceFound(count: silenceSegs.count, segments: silenceSegs))
            stageDone(.silenceCoarse, "Found \(silenceSegs.count) silence region\(silenceSegs.count == 1 ? "" : "s").")
        } catch {
            stageFail(.silenceCoarse, "Silence detection failed.")
            emit(.error(message: error.localizedDescription, stage: .silenceCoarse, stack: nil)); return
        }
        guard !Task.isCancelled else { return }

        // --- Fine silences ---
        stageStart(.silenceFine, "Detecting fine-grained silences…")
        var snapSilences: [Segment] = []
        if let fine = try? await Ffmpeg.detectSilences(
            input: extracted.wavPath, thresholdDb: -40, minSilence: 0.1,
            duration: duration, runner: runner) {
            snapSilences = fine
            stageDone(.silenceFine, "Found \(fine.count) snap point\(fine.count == 1 ? "" : "s").")
        } else {
            stageDone(.silenceFine, "Snap detection skipped.")
        }
        guard !Task.isCancelled else { return }

        // --- Whisper ---
        let whisperBin: String
        do { whisperBin = try await Whisper.assertAvailable(runner: runner) }
        catch {
            stageFail(.transcribe, "whisper-cli not found.")
            emit(.error(message: error.localizedDescription, stage: .transcribe, stack: nil)); return
        }

        stageStart(.transcribe, "Transcribing with whisper (model: \(options.whisperModel))…")
        let rawTokens: [Token]
        do {
            rawTokens = try await transcribeFromAudio(
                wavPath: extracted.wavPath,
                whisperBin: whisperBin,
                model: options.whisperModel,
                saveTranscriptPath: options.saveTranscriptPath,
                runner: runner)
            let preview = rawTokens.prefix(80).map(\.word).joined(separator: " ")
            emit(.transcript(tokenCount: rawTokens.count, preview: preview))
            stageDone(.transcribe, "Transcribed: \(rawTokens.count) word\(rawTokens.count == 1 ? "" : "s").")
        } catch {
            stageFail(.transcribe, "Transcription failed.")
            emit(.error(message: error.localizedDescription, stage: .transcribe, stack: nil)); return
        }
        // Merge sub-word pieces into whole words once; reuse for both the LLM
        // detector and the review-screen proposals so indices stay aligned.
        let mergedTokens = mergeSubwordTokens(rawTokens)
        guard !Task.isCancelled else { return }

        // --- LLM retake detection ---
        stageStart(.detectRetakes, "Detecting retakes with \(options.model) (via AI Gateway)…")
        let retakeOps: [RemoveRetakeOp]
        do {
            let client = GatewayClient(config: gateway)
            retakeOps = try await planLlmRetakeOps(
                client: client,
                model: options.model,
                mergedTokens: mergedTokens,
                snapSilences: snapSilences,
                maxRetakeRatio: options.maxRetakeRatio,
                passes: options.passes)
            stageDone(.detectRetakes, "Found \(retakeOps.count) retake\(retakeOps.count == 1 ? "" : "s").")
        } catch {
            stageFail(.detectRetakes, "Retake detection failed.")
            emit(.error(message: error.localizedDescription, stage: .detectRetakes, stack: nil)); return
        }
        guard !Task.isCancelled else { return }

        // --- Build initial plan ---
        let silenceEditOps: [EnginePlan.Op] = silenceSegs.map { .silence(RemoveSilenceOp(start: $0.start, end: $0.end)) }
        let retakeEditOps:  [EnginePlan.Op] = retakeOps.map { .retake($0) }
        var plan = buildEnginePlan(
            source: input.path, duration: duration,
            operations: silenceEditOps + retakeEditOps)

        // --- Batch review ---
        stageStart(.review, retakeOps.isEmpty ? "No retakes detected." : "Awaiting transcript review…")
        let proposals = buildReviewProposals(mergedTokens, retakeOps)

        let decision: ReviewDecision = await withCheckedContinuation { cont in
            reviewContinuation = cont
            emit(.reviewReady(
                total: retakeOps.count,
                transcript: toTranscriptTokens(mergedTokens),
                proposals: proposals))
        }
        guard !Task.isCancelled else { return }

        switch decision {
        case .cancel:
            stageFail(.review, "Cancelled.")
            return
        case .submit(let cuts):
            let approved = applyReviewResult(mergedTokens, proposals, cuts)
            let keptOps: [EnginePlan.Op] = plan.operations.filter {
                if case .retake = $0 { return false }; return true
            }
            plan = EnginePlan(source: plan.source, duration: plan.duration,
                              operations: keptOps + approved.map { .retake($0) })
            stageDone(.review, "Keeping \(approved.count) of \(retakeOps.count) cut\(retakeOps.count == 1 ? "" : "s").")
        }
        guard !Task.isCancelled else { return }

        // --- Keep segments ---
        let keep = planToKeepSegments(plan,
            leadInMs: Double(options.leadInMs),
            tailOutMs: Double(options.tailOutMs))
        guard !keep.isEmpty else {
            emit(.error(message: "Nothing left to keep after applying the plan.", stage: nil, stack: nil))
            return
        }
        let (savedSec, savedPercent) = keep.summarize(originalDuration: duration)

        // --- Render ---
        stageStart(.render, "Rendering…")
        let renderStart = Date()
        do {
            try await Ffmpeg.render(
                input: input.path,
                output: options.output,
                keep: keep,
                crf: options.crf,
                preset: options.preset,
                onProcess: { [weak self] p in
                    Task { @MainActor [weak self] in self?.activeProcess = p }
                },
                onProgress: { [emitEvent] p in
                    emitEvent(.renderProgress(
                        frame: p.frame, fps: p.fps, speed: p.speed,
                        percent: p.percent, etaSec: p.etaSec))
                },
                runner: runner)
        } catch {
            stageFail(.render, "Render failed.")
            emit(.error(message: error.localizedDescription, stage: .render, stack: nil)); return
        }
        activeProcess = nil
        let renderMs = Int(-renderStart.timeIntervalSinceNow * 1000)
        stageDone(.render, "Render complete (\(String(format: "%.1f", Double(renderMs)/1000))s).", ms: renderMs)

        let elapsedSec = -start.timeIntervalSinceNow
        emit(.done(
            plan: plan.toDonePlan(),
            output: options.output,
            savedSec: savedSec,
            savedPercent: savedPercent,
            elapsedSec: elapsedSec))
    }
}

// MARK: - Duration formatter

private func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600; let m = (total % 3600) / 60; let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
