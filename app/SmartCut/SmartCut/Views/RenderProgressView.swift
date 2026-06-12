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
            row("Removed", Formatters.shortDuration(appState.savedSoFar), tint: .green)
            row("Decisions", "\(appState.decisions.count) / \(appState.retakeTotal)")
        }
    }

    private func row(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
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
            Text("⚙️").font(.system(size: 44))
            Text("Rendering with ffmpeg").font(.system(size: 18, weight: .semibold))
            if let outputPath = outputFilename {
                HStack(spacing: 4) {
                    Text("Saving to ").foregroundStyle(.secondary)
                    Text(outputPath)
                        .font(.system(size: 12, design: .monospaced))
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
            .foregroundStyle(.secondary)

            statsRow(stats)
                .padding(.top, 6)

            Button("Cancel render") { Task { await appState.cancel() } }
                .controlSize(.large)
                .padding(.top, 16)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        )
    }

    private var outputFilename: String? {
        guard !appState.options.output.isEmpty else { return nil }
        return URL(fileURLWithPath: appState.options.output).lastPathComponent
    }

    private func progressBar(percent: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor).opacity(0.4))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
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
                .font(.system(size: 16, weight: .semibold))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .underPageBackgroundColor))
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
