import SwiftUI

struct PipelineRunningView: View {
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
            SidebarSectionHeader("Settings")
            settingsRow("Threshold", "\(Int(appState.options.thresholdDb)) dB")
            settingsRow("Min silence", String(format: "%.1fs", appState.options.minSilence))
            settingsRow("Model", appState.options.model)
            settingsRow("Passes", "\(appState.options.passes)")
            settingsRow("Whisper", appState.options.whisperModel)
        }
    }

    private func settingsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value).font(.system(size: 11))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                statusBanner
                activitySection
                whatsNext
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Processing…").font(.system(size: 22, weight: .semibold))
            Text("Running detection. You'll review proposed cuts when this finishes.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .progressViewStyle(.circular)
            VStack(alignment: .leading, spacing: 2) {
                Text(currentMessage).font(.system(size: 13, weight: .medium))
                if let detail = currentDetail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Cancel") { Task { await appState.cancel() } }
                .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.10))
        )
    }

    private var currentMessage: String {
        guard let stage = appState.currentStage else {
            return "Starting pipeline…"
        }
        switch stage {
        case .probe: return "Loading file"
        case .extractAudio: return "Extracting audio"
        case .silenceCoarse, .silenceFine: return "Detecting silence"
        case .transcribe: return "Transcribing audio with Whisper"
        case .detectRetakes: return "Detecting retakes with Claude"
        case .review: return "Awaiting review"
        case .render: return "Rendering"
        }
    }

    private var currentDetail: String? {
        guard let stage = appState.currentStage else { return nil }
        return appState.stageDetails[stage]
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Activity log")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            ActivityLogView(lines: appState.activityLog)
                .frame(minHeight: 240, maxHeight: 320)
        }
    }

    private var whatsNext: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's next")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            Text(
                "Once transcription finishes, Claude runs \(appState.options.passes) detection pass\(appState.options.passes == 1 ? "" : "es") to find retakes and false starts. You'll then review each proposed cut one-by-one before any rendering happens."
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Scrolling, fixed-height activity log. Auto-scrolls to the latest line.
struct ActivityLogView: View {
    let lines: [LogLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(timestamp(line.timestamp))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(line.text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(color(for: line.level))
                            Spacer(minLength: 0)
                        }
                        .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("__bottom__")
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .onChange(of: lines.count) {
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
        }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func timestamp(_ date: Date) -> String {
        "[\(Self.timeFmt.string(from: date))]"
    }

    private func color(for level: LogLine.Level) -> Color {
        switch level {
        case .info: return Color.accentColor
        case .ok: return .green
        case .warn: return .yellow
        case .err: return .red
        case .dim: return .secondary
        }
    }
}

#Preview {
    PipelineRunningView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
