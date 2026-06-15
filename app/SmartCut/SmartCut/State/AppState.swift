import Foundation
import Observation

// MARK: - Supporting types

struct LogLine: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: Level
    let text: String

    enum Level: Sendable {
        case info, ok, warn, err, dim
    }
}

struct RetakeProposal: Identifiable, Sendable {
    let id: String  // opId
    let op: RemoveRetakeOp
    let index: Int
    let total: Int
}

/// Mutable per-cut state for the batch transcript-review screen. Starts from
/// the AI proposal; the user can toggle it off or move its word boundaries.
struct ReviewCutState: Identifiable, Sendable {
    let opId: String
    let op: RemoveRetakeOp
    var enabled: Bool
    var removeStartIndex: Int  // inclusive transcript token index
    var removeEndIndex: Int  // inclusive transcript token index
    var id: String { opId }
}

struct RenderStats: Sendable {
    var frame: Int?
    var fps: Double?
    var speed: Double?
    var percent: Double?
    var etaSec: Double?
}

struct DoneSummary: Sendable {
    let outputPath: URL
    let originalDuration: Double
    let savedSec: Double
    let savedPercent: Double
    let silenceCuts: Int
    let retakeCuts: Int
    let retakesKept: Int
    let elapsedSec: Double
}

struct RetakeDecisionRecord: Identifiable, Sendable {
    let id = UUID()
    let opId: String
    let action: RetakeDecision
}

// MARK: - AppState

@MainActor
@Observable
final class AppState {

    enum Screen: Sendable {
        case drop
        case settings
        case running
        case review
        case render
        case done
    }

    // --- routing + input ---

    var screen: Screen = .drop
    var droppedFile: URL?
    var metadata: VideoMetadata?

    // --- settings (mirrors SmartcutConfig knobs the UI exposes) ---

    var options = StartOptions(output: "")

    // --- pipeline state ---

    var stages: [Stage: StageStatus] = [:]
    var stageDetails: [Stage: String] = [:]
    var currentStage: Stage?
    var activityLog: [LogLine] = []
    var errorMessage: String?

    // --- retake review ---

    var currentRetake: RetakeProposal?
    var retakeTotal: Int = 0
    var decisions: [RetakeDecisionRecord] = []

    /// True when the pipeline paused at review with zero retakes and is
    /// awaiting a confirm-to-render decision.
    var awaitingReviewConfirmation = false

    // --- batch transcript review ---

    /// Full transcript (whole words + timing) for the review screen.
    var transcript: [TranscriptToken] = []
    /// Editable per-cut state, chronologically ordered (mirrors the proposals).
    var reviewCuts: [ReviewCutState] = []

    var enabledCutCount: Int { reviewCuts.filter(\.enabled).count }

    /// Estimated total time removed by the currently-enabled cuts.
    var reviewSavedEstimate: Double {
        reviewCuts.filter(\.enabled).reduce(0) { $0 + estimatedDuration($1) }
    }

    /// Seconds removed by a single cut, derived from its word boundaries:
    /// from the first removed word's start to the next kept word's onset.
    func estimatedDuration(_ cut: ReviewCutState) -> Double {
        guard !transcript.isEmpty else { return 0 }
        let s = max(0, min(cut.removeStartIndex, transcript.count - 1))
        let e = max(s, min(cut.removeEndIndex, transcript.count - 1))
        let start = transcript[s].start
        let end = e + 1 < transcript.count ? transcript[e + 1].start : transcript[e].end
        return max(0, end - start)
    }

    var removedCount: Int { decisions.filter { $0.action == .remove }.count }
    var keptCount: Int { decisions.filter { $0.action == .keep }.count }
    var savedSoFar: Double {
        decisions
            .filter { $0.action == .remove || $0.action == .approveRest }
            .compactMap { record in
                // Look up the op duration from the proposal we already
                // recorded — currentRetake gets nil'd after decision, so
                // we keep durations alongside the record.
                proposalDurations[record.opId]
            }
            .reduce(0, +)
    }
    private var proposalDurations: [String: Double] = [:]

    // --- render ---

    var renderStats = RenderStats()

    // --- done ---

    var summary: DoneSummary?

    // --- config + preferences ---

    var config: AppConfig
    var preferences: AppPreferences
    /// True when the first-run sheet should be shown (missing required
    /// secrets). Bound by `ContentView` as the sheet trigger.
    var needsFirstRunConfig: Bool

    // --- dependencies ---

    private(set) var sidecar: SidecarClient!

    init() {
        let loadedConfig = AppConfig.load()
        let loadedPrefs = AppPreferences.load()
        self.config = loadedConfig
        self.preferences = loadedPrefs
        self.needsFirstRunConfig = !loadedConfig.hasRequiredSecrets
        self.options = loadedPrefs.makeStartOptions()

        // SidecarClient needs a reference back to us for event dispatch.
        // Capture-then-bind dance to avoid passing `self` before `self`
        // is fully initialized.
        self.sidecar = SidecarClient(
            config: .from(loadedConfig),
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event: event) }
            },
            onExit: { [weak self] status in
                Task { @MainActor in self?.handleSidecarExit(status: status) }
            }
        )
    }

    /// Persist a new `AppConfig` and rebuild the sidecar so the new
    /// node path / env reach the next spawn.
    func saveConfig(_ newConfig: AppConfig) {
        do {
            try newConfig.save()
            config = newConfig
            needsFirstRunConfig = !newConfig.hasRequiredSecrets
            rebuildSidecar()
        } catch {
            errorMessage = "Could not save config: \(error.localizedDescription)"
        }
    }

    /// Tear down and recreate the SidecarClient. Called by the error
    /// banner's "Restart sidecar" button.
    func restartSidecar() {
        rebuildSidecar()
        errorMessage = nil
        appendLog(.info, "Sidecar restarted")
    }

    /// Dismiss the current error banner and return to the drop screen.
    /// Rebuilds the sidecar silently so a crashed process is recovered
    /// without exposing implementation details to the user.
    func dismissError() {
        rebuildSidecar()
        resetToDrop()
    }

    private func rebuildSidecar() {
        sidecar.stop()
        sidecar = SidecarClient(
            config: .from(config),
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event: event) }
            },
            onExit: { [weak self] status in
                Task { @MainActor in self?.handleSidecarExit(status: status) }
            }
        )
    }

    // MARK: - User actions

    func handleDrop(_ url: URL) async {
        droppedFile = url
        metadata = nil
        errorMessage = nil
        // Re-seed options each drop so user-tweaked previous-run state
        // doesn't bleed into the next file.
        options = preferences.makeStartOptions()
        options.output = defaultOutputPath(for: url)

        do {
            let md = try await sidecar.getMetadata(path: url)
            metadata = md
            screen = .settings
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func startProcessing() async {
        guard let input = droppedFile else { return }

        // Snapshot the current options into preferences so the next
        // session picks up the user's last-used settings.
        preferences.update(from: options)
        if let dir = parentDir(of: options.output) {
            preferences.outputDirectory = dir
        }
        try? preferences.save()

        resetPipelineState()
        screen = .running
        currentStage = nil

        do {
            _ = try await sidecar.start(input: input, options: options)
        } catch {
            errorMessage = error.localizedDescription
            appendLog(.err, error.localizedDescription)
        }
    }

    private func parentDir(of path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return url.deletingLastPathComponent().path
    }

    func decide(_ action: RetakeDecision) async {
        guard let current = currentRetake else { return }
        decisions.append(.init(opId: current.id, action: action))
        proposalDurations[current.id] = current.op.duration
        currentRetake = nil

        // Optimistically log the decision so the activity log doesn't
        // wait for the server's `retakeDecision` event.
        let label: String = {
            switch action {
            case .remove: return "Removed"
            case .keep: return "Kept"
            case .approveRest: return "Approved all remaining"
            case .cancel: return "Cancelled review"
            }
        }()
        appendLog(.info, "\(label) cut \(current.index + 1)/\(current.total)")

        do {
            try await sidecar.decide(opId: current.id, action: action)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Confirm rendering when the pipeline paused at review with zero retakes.
    func confirmRender() async {
        awaitingReviewConfirmation = false
        appendLog(.info, "No retakes — proceeding to render")
        do {
            try await sidecar.decide(opId: "review-confirm", action: .approveRest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Batch review mutations

    func setCutEnabled(_ opId: String, _ enabled: Bool) {
        guard let i = reviewCuts.firstIndex(where: { $0.opId == opId }) else { return }
        reviewCuts[i].enabled = enabled
    }

    /// Move a cut's start boundary to `index`, clamped so it can't cross the
    /// cut's own end or overlap the previous cut.
    func adjustCutStart(_ opId: String, to index: Int) {
        guard let i = reviewCuts.firstIndex(where: { $0.opId == opId }) else { return }
        let lower = i > 0 ? reviewCuts[i - 1].removeEndIndex + 1 : 0
        reviewCuts[i].removeStartIndex = max(lower, min(index, reviewCuts[i].removeEndIndex))
    }

    /// Move a cut's end boundary to `index`, clamped so it can't cross the
    /// cut's own start or overlap the next cut.
    func adjustCutEnd(_ opId: String, to index: Int) {
        guard let i = reviewCuts.firstIndex(where: { $0.opId == opId }) else { return }
        let upper =
            i < reviewCuts.count - 1
            ? reviewCuts[i + 1].removeStartIndex - 1
            : transcript.count - 1
        reviewCuts[i].removeEndIndex = min(upper, max(index, reviewCuts[i].removeStartIndex))
    }

    /// Submit the (possibly adjusted) cuts and proceed to render.
    func applyReview() async {
        let cuts = reviewCuts.map {
            ReviewCutDecision(
                opId: $0.opId,
                enabled: $0.enabled,
                removeStartIndex: $0.removeStartIndex,
                removeEndIndex: $0.removeEndIndex
            )
        }
        awaitingReviewConfirmation = false
        appendLog(.info, "Applying \(enabledCutCount) of \(reviewCuts.count) cut(s)")
        do {
            try await sidecar.submitReview(cuts: cuts)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() async {
        do { try await sidecar.cancel() } catch {
            errorMessage = error.localizedDescription
        }
        resetToDrop()
    }

    func resetToDrop() {
        screen = .drop
        droppedFile = nil
        metadata = nil
        options = StartOptions(output: "")
        resetPipelineState()
        summary = nil
        errorMessage = nil
    }

    // MARK: - Event handling

    private func handle(event: PipelineEvent) {
        switch event {

        case .stage(let stage, let status, let message, let durationMs):
            stages[stage] = status
            if let message { stageDetails[stage] = message }
            if status == .start {
                currentStage = stage
                appendLog(.info, "▸ \(message ?? stage.displayName)")
            } else if status == .done {
                let suffix = durationMs.map { " (\(Double($0) / 1000.0)s)" } ?? ""
                appendLog(.ok, "✓ \(message ?? "done")\(suffix)")

                // Route on stage transitions that mark a screen change.
                switch stage {
                case .render:
                    // `.done` event fires shortly after; render screen
                    // keeps showing 100% briefly.
                    break
                default:
                    break
                }
            } else {
                currentStage = nil
                appendLog(.err, "✖ \(message ?? "failed")")
                if stage == .review {
                    // Review cancelled by user.
                    resetToDrop()
                }
            }

            // Auto-route into render when render starts.
            if stage == .render && status == .start {
                screen = .render
            }

        case .progress(let stage, _, _, _, let note):
            if let note { appendLog(.dim, "… \(note)"); _ = stage }

        case .metadata(let durationSec, let sizeBytes, let codec, let width, let height):
            metadata = VideoMetadata(
                durationSec: durationSec,
                sizeBytes: sizeBytes,
                codec: codec,
                width: width,
                height: height
            )

        case .silenceFound(let count, _):
            appendLog(.dim, "… \(count) silence region\(count == 1 ? "" : "s") found")

        case .transcript(let tokenCount, let preview):
            appendLog(
                .dim,
                "… transcript: \(tokenCount) words. Preview: \"\(String(preview.prefix(80)))…\"")

        case .reviewReady(let total, let tokens, let proposals):
            retakeTotal = total
            transcript = tokens
            reviewCuts = proposals.map {
                ReviewCutState(
                    opId: $0.opId,
                    op: $0.op,
                    enabled: true,
                    removeStartIndex: $0.removeStartIndex,
                    removeEndIndex: $0.removeEndIndex
                )
            }
            awaitingReviewConfirmation = proposals.isEmpty
            currentRetake = nil
            if screen != .review { screen = .review }

        case .retakeProposed(let opId, let op, let index, let total):
            retakeTotal = total
            currentRetake = RetakeProposal(id: opId, op: op, index: index, total: total)
            if screen != .review { screen = .review }

        case .retakeDecisionAck:
            // Already optimistically logged in decide(); ignore.
            break

        case .renderProgress(let frame, let fps, let speed, let percent, let etaSec):
            renderStats = RenderStats(
                frame: frame,
                fps: fps,
                speed: speed,
                percent: percent,
                etaSec: etaSec
            )

        case .done(let plan, let output, let savedSec, let savedPercent, let elapsedSec):
            let outURL = URL(fileURLWithPath: output)
            let retakesProposed = decisions.count
            // "Kept" = proposals the user disabled (batch flow) or chose to keep
            // (legacy per-cut flow).
            let retakesKept =
                reviewCuts.isEmpty
                ? decisions.filter { $0.action == .keep }.count
                : reviewCuts.filter { !$0.enabled }.count
            summary = DoneSummary(
                outputPath: outURL,
                originalDuration: plan.duration,
                savedSec: savedSec,
                savedPercent: savedPercent,
                silenceCuts: plan.silenceOperations.count,
                retakeCuts: plan.retakeOperations.count,
                retakesKept: retakesKept,
                elapsedSec: elapsedSec
            )
            _ = retakesProposed
            screen = .done
            appendLog(
                .ok,
                "Saved \(String(format: "%.1f", savedSec))s (\(String(format: "%.1f", savedPercent))%)"
            )

        case .error(let message, let stage, _):
            errorMessage = message
            appendLog(.err, "ERROR\(stage.map { " (\($0.rawValue))" } ?? ""): \(message)")

        case .unknown:
            break
        }
    }

    private func handleSidecarExit(status: Int32) {
        guard status != 0 && summary == nil else { return }
        let tail = sidecar.stderrSnapshot
        let lastLine = tail
            .split(separator: "\n")
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? ""
        let detail = lastLine.isEmpty ? "" : " — \(lastLine)"
        errorMessage = "Sidecar exited unexpectedly (status \(status))\(detail)"
        appendLog(.err, errorMessage ?? "Sidecar exited")
    }

    // MARK: - Convenience for the error banner

    /// Last N activity log lines, newest first. Used by the banner's
    /// "Show details" expander.
    func recentLogLines(limit: Int = 20) -> [LogLine] {
        Array(activityLog.suffix(limit).reversed())
    }

    /// Snapshot of the sidecar's stderr tail for the banner.
    var sidecarStderrSnapshot: String { sidecar?.stderrSnapshot ?? "" }

    // MARK: - Helpers

    private func resetPipelineState() {
        stages.removeAll()
        stageDetails.removeAll()
        currentStage = nil
        activityLog.removeAll()
        currentRetake = nil
        retakeTotal = 0
        awaitingReviewConfirmation = false
        transcript.removeAll()
        reviewCuts.removeAll()
        decisions.removeAll()
        proposalDurations.removeAll()
        renderStats = RenderStats()
        summary = nil
    }

    private func appendLog(_ level: LogLine.Level, _ text: String) {
        activityLog.append(LogLine(timestamp: Date(), level: level, text: text))
        // Cap so the log doesn't grow without bound during long runs.
        if activityLog.count > 500 {
            activityLog.removeFirst(activityLog.count - 500)
        }
    }

    private func defaultOutputPath(for input: URL) -> String {
        let dir: URL
        if let configured = preferences.outputDirectory, !configured.isEmpty {
            dir = URL(fileURLWithPath: configured)
        } else {
            dir = input.deletingLastPathComponent()
        }
        let stem = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.isEmpty ? "mp4" : input.pathExtension
        return dir.appendingPathComponent("\(stem)-smart.\(ext)").path
    }
}
