import SwiftUI

/// Single retake review card. Renders one proposal and exposes the four
/// actions (remove / keep / approve all / cancel). Audio buttons are
/// placeholders until Phase 3.6 wires AudioPlayer.
struct RetakeCardView: View {
    @Environment(AppState.self) private var appState

    let proposal: RetakeProposal

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            removedSection
            reasonSection
            stitchedSection
            audioRow
            actionRow
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        )
    }

    private var op: RemoveRetakeOp { proposal.op }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Possible retake")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 8) {
                    Text("\(Formatters.time(op.start)) → \(Formatters.time(op.end))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("−\(Formatters.shortDuration(op.duration))")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.red.opacity(0.16))
                        )
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            ConfidenceBadge(value: op.confidence)
        }
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel("Remove this")
            Text("\u{201C}\(op.removedText)\u{201D}")
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.08))
                )
        }
    }

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel("Why")
            Text(op.reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stitchedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel("Result if removed")
            VStack(alignment: .leading, spacing: 0) {
                stitched
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .underPageBackgroundColor))
            )
        }
    }

    private var stitched: some View {
        let before = op.contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = op.keptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = op.contextAfter.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = Text("")
        if !before.isEmpty {
            text = text + Text("…\(before) ").foregroundStyle(.secondary)
        }
        text = text + Text(kept).foregroundStyle(.green)
        if !after.isEmpty {
            text = text + Text(" \(after)…").foregroundStyle(.secondary)
        }
        return text.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }

    private var audioRow: some View {
        HStack(spacing: 10) {
            audioButton(
                title: "Play removed clip (\(Formatters.shortDuration(op.duration)))",
                tint: .secondary
            )
            audioButton(title: "Play stitched preview", tint: .accentColor)
        }
    }

    private func audioButton(title: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill").foregroundStyle(tint)
            Text(title).font(.system(size: 12))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        )
        .opacity(0.55)
        .help("Audio preview lands in Phase 3.6")
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button { Task { await appState.decide(.remove) } } label: {
                Label("Remove section", systemImage: "scissors")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Button { Task { await appState.decide(.keep) } } label: {
                Label("Keep it", systemImage: "checkmark")
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)

            Button { Task { await appState.decide(.approveRest) } } label: {
                Label("Approve all remaining", systemImage: "checkmark.circle.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()

            Button("Cancel") { Task { await appState.cancel() } }
                .controlSize(.large)
        }
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
    }
}

private struct ConfidenceBadge: View {
    let value: Double  // 0-100

    var body: some View {
        let clamped = max(0, min(100, value))
        VStack(alignment: .trailing, spacing: 6) {
            Text("CONFIDENCE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                bar
                Text(String(format: "%.0f%%", clamped))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
        }
    }

    private var tint: Color {
        if value >= 80 { return .green }
        if value >= 50 { return .yellow }
        return .red
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .separatorColor))
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * value / 100))
            }
        }
        .frame(width: 70, height: 6)
    }
}
