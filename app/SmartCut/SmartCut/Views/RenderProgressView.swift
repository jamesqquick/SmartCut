import SwiftUI

struct RenderProgressView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        AppShell {
            sidebar
        } content: {
            content
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        StepperView()

        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader("Plan summary")
            row("Silence cuts", "\(decisionsSilenceCount)")
            row("Retake cuts", "\(appState.removedCount + approvedRestCount)")
            row("Removed", Formatters.shortDuration(appState.savedSoFar), tint: Theme.good)
            row("Decisions", "\(appState.decisions.count) / \(appState.retakeTotal)")
        }
    }

    private func row(_ label: String, _ value: String, tint: Color = Theme.ink) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(tint)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
    }

    private var decisionsSilenceCount: Int {
        // We don't have the plan yet during render; the `done` event will
        // bring it in. While rendering, default to 0; sidebar updates the
        // moment summary lands.
        appState.summary?.silenceCuts ?? 0
    }

    private var approvedRestCount: Int {
        appState.decisions.filter { $0.action == .approveRest }.count
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            Spacer()
            card
                .frame(maxWidth: 540)
            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var card: some View {
        let stats = appState.renderStats
        let percent = stats.percent ?? 0

        return VStack(spacing: 16) {
            Image(systemName: "gearshape.2")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Theme.indigo)
                .symbolEffect(.pulse, options: .repeating)
            Text("Rendering with ffmpeg")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.ink)
            if let outputPath = outputFilename {
                HStack(spacing: 4) {
                    Text("Saving to ").foregroundStyle(Theme.muted)
                    Text(outputPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.bodyText)
                }
                .font(.system(size: 12))
            }

            progressBar(percent: percent)
                .frame(height: 6)

            HStack(spacing: 6) {
                Text(Formatters.percent(percent, fractionDigits: 0))
                if let eta = stats.etaSec, eta.isFinite, eta > 0 {
                    Text("·")
                    Text("~\(Formatters.shortDuration(eta)) remaining")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)

            statsRow(stats)
                .padding(.top, 6)

            Button("Cancel render") { Task { await appState.cancel() } }
                .buttonStyle(.scSecondary)
                .padding(.top, 16)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.elevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
                .shadow(color: Color(srgb: 0x32325D).opacity(0.12), radius: 24, x: 0, y: 12)
        )
    }

    private var outputFilename: String? {
        guard !appState.options.output.isEmpty else { return nil }
        return URL(fileURLWithPath: appState.options.output).lastPathComponent
    }

    private func progressBar(percent: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(Theme.border)
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(Theme.indigo)
                    .frame(width: max(0, geo.size.width * max(0, min(100, percent)) / 100))
                    .animation(.easeOut(duration: 0.2), value: percent)
            }
        }
    }

    private func statsRow(_ stats: RenderStats) -> some View {
        HStack(spacing: 16) {
            tile(value: stats.frame.map { "\($0)" } ?? "—", label: "Frames")
            tile(value: stats.speed.map { String(format: "%.2f×", $0) } ?? "—", label: "Speed")
            tile(value: stats.fps.map { String(format: "%.0f", $0) } ?? "—", label: "fps")
            tile(value: etaLabel(stats.etaSec), label: "ETA")
        }
    }

    private func tile(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.ink)
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .regular))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
    }

    private func etaLabel(_ eta: Double?) -> String {
        guard let eta, eta.isFinite, eta > 0 else { return "—" }
        return Formatters.shortDuration(eta)
    }
}

#Preview {
    RenderProgressView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
