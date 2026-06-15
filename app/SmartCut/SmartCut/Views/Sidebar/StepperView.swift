import SwiftUI

/// Vertical pipeline stepper that appears in the sidebar on every screen
/// other than `.drop`. Each row shows a stage's status (pending, active,
/// done, fail) plus an optional meta line (e.g. "47 regions").
struct StepperView: View {
    @Environment(AppState.self) private var appState

    private let order: [Stage] = [
        .probe,
        .extractAudio,
        .silenceCoarse,
        .transcribe,
        .detectRetakes,
        .review,
        .render,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SidebarSectionHeader("Pipeline")
            ForEach(order, id: \.self) { stage in
                row(for: stage)
            }
        }
    }

    private func row(for stage: Stage) -> some View {
        let status = appState.stages[stage]
        let isActive = appState.currentStage == stage && status == .start
        let isDone = status == .done
        let isFail = status == .fail

        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(dotColor(active: isActive, done: isDone, fail: isFail))
                    .frame(width: 9, height: 9)
                if isActive {
                    Circle()
                        .stroke(Theme.indigo.opacity(0.5), lineWidth: 2)
                        .frame(width: 15, height: 15)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: stage, status: status))
                    .font(.system(size: 12))
                    .foregroundStyle(isActive || isDone ? Theme.ink : Theme.muted)
                if let meta = meta(for: stage) {
                    Text(meta)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 10)
        .background(isActive ? Theme.wash : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private func dotColor(active: Bool, done: Bool, fail: Bool) -> Color {
        if fail { return Theme.danger }
        if done { return Theme.good }
        if active { return Theme.indigo }
        return Theme.borderStrong
    }

    private func label(for stage: Stage, status: StageStatus?) -> String {
        // While a stage is in flight, present-tense reads better.
        switch (stage, status) {
        case (.probe, .start): return "Loading file"
        case (.extractAudio, .start): return "Extracting audio"
        case (.silenceCoarse, .start): return "Detecting silence"
        case (.transcribe, .start): return "Transcribing"
        case (.detectRetakes, .start): return "Detecting retakes"
        case (.review, .start): return "Review"
        case (.render, .start): return "Rendering"
        default: return stage.displayName
        }
    }

    private func meta(for stage: Stage) -> String? {
        switch stage {
        case .review:
            if appState.retakeTotal > 0 {
                let current = (appState.currentRetake?.index ?? appState.decisions.count - 1) + 1
                return "Cut \(min(current, appState.retakeTotal)) of \(appState.retakeTotal)"
            }
            return nil
        case .render:
            if let pct = appState.renderStats.percent, appState.stages[.render] == .start {
                if let eta = appState.renderStats.etaSec, eta.isFinite, eta > 0 {
                    return "\(Formatters.percent(pct, fractionDigits: 0)) · \(Formatters.shortDuration(eta)) left"
                }
                return Formatters.percent(pct, fractionDigits: 0)
            }
            return nil
        default:
            return appState.stageDetails[stage].map { compact($0) }
        }
    }

    /// Trim a stage's tail message to fit the sidebar.
    private func compact(_ s: String) -> String {
        s.count > 28 ? String(s.prefix(28)) + "…" : s
    }
}

struct SidebarSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .regular))
            .tracking(0.8)
            .foregroundStyle(Theme.muted)
            .padding(.bottom, 8)
            .padding(.horizontal, 10)
    }
}
