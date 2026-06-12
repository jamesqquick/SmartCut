import SwiftUI

/// Overlay banner that surfaces `AppState.errorMessage`. Pinned to the
/// top of `ContentView`, above the active screen. Includes a
/// "Show details" expander revealing the last ~20 activity log lines,
/// plus Dismiss and Restart sidecar buttons.
struct ErrorBanner: View {
    @Environment(AppState.self) private var appState
    let message: String

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: 16))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(expanded ? "Hide details" : "Show details") {
                            withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                        Button("Restart sidecar") {
                            appState.restartSidecar()
                        }
                        .controlSize(.small)

                        Button("Dismiss") {
                            appState.dismissError()
                        }
                        .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)

            if expanded {
                Divider()
                detailsBlock
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: 200)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.red.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private var detailsBlock: some View {
        let lines = appState.recentLogLines(limit: 20)
        let stderr = appState.sidecarStderrSnapshot
            .split(separator: "\n")
            .suffix(6)
            .joined(separator: "\n")

        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !lines.isEmpty {
                    sectionTitle("RECENT ACTIVITY")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line.level))
                        }
                    }
                }

                if !stderr.isEmpty {
                    sectionTitle("SIDECAR STDERR (TAIL)")
                    Text(stderr)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
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
