import SwiftUI

/// Single retake review card. Renders one proposal and exposes the four
/// actions (remove / keep / approve all / cancel) plus two audio
/// previews backed by AudioPlayer + SidecarClient.extractClip /
/// extractStitchedClip.
struct RetakeCardView: View {
    @Environment(AppState.self) private var appState
    @State private var audio = AudioPlayer()

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
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
        // When the user advances to the next proposal, stop any preview
        // audio that's still spooling from the previous one.
        .onChange(of: proposal.id) { _, _ in
            audio.stop()
        }
        .onDisappear { audio.stop() }
    }

    private var op: RemoveRetakeOp { proposal.op }
    private var removedKey: String { "removed-\(proposal.id)" }
    private var stitchedKey: String { "stitched-\(proposal.id)" }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Possible retake")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 8) {
                    Text("\(Formatters.time(op.start)) → \(Formatters.time(op.end))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                    Text("−\(Formatters.shortDuration(op.duration))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radiusSmall)
                                .fill(Theme.danger.opacity(0.12))
                        )
                        .foregroundStyle(Theme.danger)
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
                .foregroundStyle(Theme.danger)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.danger.opacity(0.08))
                )
        }
    }

    private var reasonSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel("Why")
            Text(op.reason)
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
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
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
            )
        }
    }

    private var stitched: some View {
        let before = op.contextBefore.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = op.keptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = op.contextAfter.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = Text("")
        if !before.isEmpty {
            text = text + Text("…\(before) ").foregroundStyle(Theme.tertiary)
        }
        text = text + Text(kept).foregroundStyle(Theme.good)
        if !after.isEmpty {
            text = text + Text(" \(after)…").foregroundStyle(Theme.tertiary)
        }
        return text.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
    }

    private var audioRow: some View {
        HStack(spacing: 10) {
            audioButton(
                key: removedKey,
                title: "Play removed clip (\(Formatters.shortDuration(op.duration)))",
                tint: Theme.good,
                action: playRemovedClip
            )
            audioButton(
                key: stitchedKey,
                title: "Play stitched preview",
                tint: Theme.teal,
                action: playStitchedPreview
            )
            if let error = audio.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
            }
        }
    }

    private func audioButton(
        key: String, title: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        let active = audio.currentKey == key
        let loading = active && audio.isLoading
        let playing = active && audio.isPlaying
        let symbol = playing ? "pause.fill" : "play.fill"

        return Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().controlSize(.small)
                        .progressViewStyle(.circular)
                        .scaleEffect(0.65)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.ink)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(
                                playing ? Theme.indigo : Theme.borderStrong,
                                lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private func playRemovedClip() {
        guard let input = appState.droppedFile else { return }
        let sidecar = appState.sidecar!
        let removeStart = op.start
        let removeEnd = op.end
        audio.play(key: removedKey) {
            let clip = try await sidecar.extractClip(
                input: input, startSec: removeStart, endSec: removeEnd)
            return URL(fileURLWithPath: clip.path)
        }
    }

    private func playStitchedPreview() {
        guard let input = appState.droppedFile else { return }
        let sidecar = appState.sidecar!
        let removeStart = op.start
        let removeEnd = op.end
        audio.play(key: stitchedKey) {
            let clip = try await sidecar.extractStitchedClip(
                input: input,
                removeStart: removeStart,
                removeEnd: removeEnd
            )
            return URL(fileURLWithPath: clip.path)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Button { Task { await appState.decide(.remove) } } label: {
                    Label("Remove section", systemImage: "scissors")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.danger)
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [])
                KeyBadge("R")
            }

            HStack(spacing: 6) {
                Button { Task { await appState.decide(.keep) } } label: {
                    Label("Keep it", systemImage: "checkmark")
                        .padding(.horizontal, 6)
                }
                .controlSize(.large)
                .keyboardShortcut("k", modifiers: [])
                KeyBadge("K")
            }

            HStack(spacing: 6) {
                Button { Task { await appState.decide(.approveRest) } } label: {
                    Label("Approve all remaining", systemImage: "checkmark.circle.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("a", modifiers: [])
                KeyBadge("A")
            }

            Spacer()

            HStack(spacing: 6) {
                Button("Cancel") { Task { await appState.cancel() } }
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                KeyBadge("Esc")
            }
        }
    }
}

private struct KeyBadge: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .stroke(Theme.borderStrong, lineWidth: 1)
            )
            .foregroundStyle(Theme.muted)
    }
}

private struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .regular))
            .tracking(0.8)
            .foregroundStyle(Theme.muted)
    }
}

private struct ConfidenceBadge: View {
    let value: Double  // 0-100

    var body: some View {
        let clamped = max(0, min(100, value))
        VStack(alignment: .trailing, spacing: 6) {
            Text("CONFIDENCE")
                .font(.system(size: 9, weight: .regular))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                bar
                Text(String(format: "%.0f%%", clamped))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(Theme.border)
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(Theme.indigo)
                    .frame(width: max(2, geo.size.width * value / 100))
            }
        }
        .frame(width: 70, height: 6)
    }
}
