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

    // --- dependencies ---

    private(set) var sidecar: SidecarClient!

    init() {
        // SidecarClient needs a reference back to us for event dispatch.
        // Capture-then-bind dance to avoid passing `self` before `self`
        // is fully initialized.
        self.sidecar = SidecarClient(
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
        options.output = AppState.defaultOutputPath(for: url)

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

    func cancel() async {
        do { try await sidecar.cancel() } catch {
            errorMessage = error.localizedDescription
        }
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
            let retakesKept = decisions.filter { $0.action == .keep }.count
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
        if status != 0 && summary == nil {
            errorMessage = "Sidecar exited unexpectedly (status \(status))."
            appendLog(.err, errorMessage!)
        }
    }

    // MARK: - Helpers

    private func resetPipelineState() {
        stages.removeAll()
        stageDetails.removeAll()
        currentStage = nil
        activityLog.removeAll()
        currentRetake = nil
        retakeTotal = 0
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

    private static func defaultOutputPath(for input: URL) -> String {
        let dir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let ext = input.pathExtension.isEmpty ? "mp4" : input.pathExtension
        return dir.appendingPathComponent("\(stem)-smart.\(ext)").path
    }
}
