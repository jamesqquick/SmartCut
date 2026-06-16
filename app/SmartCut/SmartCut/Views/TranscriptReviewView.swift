import AppKit
import AVFoundation
import SwiftUI

/// Batch transcript review: shows the entire transcript with every AI-suggested
/// retake cut highlighted over the words. The user can resize any cut by
/// dragging its word-level handles (or with arrow keys), toggle cuts on/off,
/// create new cuts by selecting words (click then Shift-click), then apply all
/// changes at once.
struct TranscriptReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    /// Shared audio player — one instance means playing one chip stops any other.
    @State private var audio = AudioPlayer()
    /// The cut currently being edited (its handles are shown + draggable).
    @State private var activeCutId: String?
    /// Anchor word of an in-progress manual selection: set by a plain click on a
    /// free word, consumed by a Shift-click that creates the cut.
    @State private var selectionAnchor: Int?
    /// Frame of each transcript word in the "tx" coordinate space, for handle
    /// placement and drag hit-testing.
    @State private var wordFrames: [Int: CGRect] = [:]
    @FocusState private var transcriptFocused: Bool

    var body: some View {
        AppShell {
            sidebar
        } content: {
            content
        }
        .onAppear {
            if activeCutId == nil { activeCutId = appState.reviewCuts.first?.opId }
        }
    }

    private var activeCut: ReviewCutState? {
        appState.reviewCuts.first { $0.opId == activeCutId }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        StepperView()

        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader("Review")
            statRow("Cuts enabled", "\(appState.enabledCutCount) / \(appState.reviewCuts.count)")
            statRow(
                "Est. time saved",
                Formatters.shortDuration(appState.reviewSavedEstimate),
                tint: Theme.good
            )
            statRow("Words", "\(appState.transcript.count)")
        }
    }

    private func statRow(_ label: String, _ value: String, tint: Color = Theme.ink) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 16)

            if !appState.reviewCuts.isEmpty {
                cutStrip
                    .padding(.horizontal, 36)
                    .padding(.bottom, 14)
            }

            Divider().background(Theme.border)

            transcriptScroll
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REVIEW")
                    .font(.system(size: 10))
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
                Text(appState.reviewCuts.isEmpty ? "No retakes detected" : "Review cuts")
                    .font(.system(size: 28, weight: .light))
                    .gradientTitle(colorScheme)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bodyText)
            }
            Spacer()
            HStack(spacing: 12) {
                Button("Cancel") { Task { await appState.cancel() } }
                    .buttonStyle(.scSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(action: { Task { await appState.applyReview() } }) {
                    Text(applyLabel).frame(minWidth: 120)
                }
                .buttonStyle(.scPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var headerSubtitle: String {
        if appState.reviewCuts.isEmpty {
            return "Only silence cuts will be applied. Render the result?"
        }
        return "Click a word then Shift-click another to cut that range. Select a cut to drag its handles (or use ← →, ⌥← ⌥→). Toggle a cut off to keep that take, or delete a manual cut with ×."
    }

    private var applyLabel: String {
        if appState.reviewCuts.isEmpty { return "Render" }
        return "Apply \(appState.enabledCutCount) cut\(appState.enabledCutCount == 1 ? "" : "s")"
    }

    // MARK: - Cut strip

    private var cutStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(appState.reviewCuts.enumerated()), id: \.element.opId) { idx, cut in
                    cutChip(index: idx, cut: cut)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cutChip(index: Int, cut: ReviewCutState) -> some View {
        let isActive = cut.opId == activeCutId
        let previewKey = "preview-\(cut.opId)"
        let isThisLoading = audio.currentKey == previewKey && audio.isLoading
        let isThisPlaying = audio.currentKey == previewKey && audio.isPlaying
        return Button {
            activeCutId = cut.opId
            transcriptFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Cut \(index + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(cut.enabled ? Theme.ink : Theme.muted)
                    Spacer(minLength: 8)
                    if cut.source == .manual {
                        Button {
                            deleteCut(cut.opId)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Delete this cut")
                    }
                    previewButton(cut: cut, key: previewKey,
                                  isLoading: isThisLoading, isPlaying: isThisPlaying)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { cut.enabled },
                            set: { appState.setCutEnabled(cut.opId, $0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                cutSourceLabel(cut)
                Text(Formatters.shortDuration(appState.estimatedDuration(cut)) + " removed")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(cut.enabled ? Theme.danger : Theme.muted)
            }
            .padding(10)
            .frame(width: 184, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(isActive ? Theme.wash : Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(isActive ? Theme.indigo : Theme.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// Small play / loading-spinner / stop button for a cut chip.
    @ViewBuilder
    private func previewButton(
        cut: ReviewCutState,
        key: String,
        isLoading: Bool,
        isPlaying: Bool
    ) -> some View {
        Button {
            if isLoading || isPlaying {
                audio.stop()
            } else {
                playPreview(for: cut, key: key)
            }
        } label: {
            ZStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.mini)
                        .tint(Theme.indigo)
                } else if isPlaying {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.indigo)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.indigo)
                }
            }
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(isPlaying ? Theme.indigo.opacity(0.15) : Theme.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                            .stroke(isPlaying ? Theme.indigo : Theme.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Stop preview" : "Preview this cut (2.5s before + 2.5s after)")
        .animation(.easeOut(duration: 0.12), value: isLoading)
        .animation(.easeOut(duration: 0.12), value: isPlaying)
    }

    private func playPreview(for cut: ReviewCutState, key: String) {
        guard let input = appState.droppedFile,
              let duration = appState.metadata?.durationSec
        else { return }

        let (focusStart, focusEnd) = appState.sourceTimes(for: cut)
        guard focusEnd > focusStart else { return }

        // Include the previewed cut even if disabled so the user hears what
        // the boundary would sound like with it applied.
        let cuts = appState.cutsAsSegments(including: cut.opId)
        let silences = appState.silenceSegments
        let leadInMs = appState.options.leadInMs
        let tailOutMs = appState.options.tailOutMs
        let sidecar = appState.sidecar!

        audio.play(key: key) {
            let clip = try await sidecar.extractEditedPreview(
                input: input,
                duration: duration,
                focusStart: focusStart,
                focusEnd: focusEnd,
                padSec: 2.5,
                tailSec: 2.5,
                leadInMs: leadInMs,
                tailOutMs: tailOutMs,
                cuts: cuts,
                silences: silences
            )
            return URL(fileURLWithPath: clip.path)
        }
    }

    /// Second line of a cut chip: a "Manual" tag for user-created cuts, or the
    /// AI confidence for suggested cuts.
    @ViewBuilder
    private func cutSourceLabel(_ cut: ReviewCutState) -> some View {
        if cut.source == .manual {
            Text("Manual")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Theme.indigo)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Theme.wash)
                )
        } else if let op = cut.op {
            Text("\(Int(op.confidence))% confidence")
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
    }

    /// Delete a cut and clear the active selection if it pointed at that cut.
    private func deleteCut(_ opId: String) {
        appState.deleteCut(opId)
        if activeCutId == opId { activeCutId = appState.reviewCuts.first?.opId }
    }

    // MARK: - Transcript

    private var transcriptScroll: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                WordFlowLayout(spacing: 4, lineSpacing: 8) {
                    ForEach(appState.transcript.indices, id: \.self) { i in
                        wordView(i)
                    }
                }
                handleOverlay
            }
            .coordinateSpace(name: "tx")
            .onPreferenceChange(WordFrameKey.self) { wordFrames = $0 }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .focusable()
        .focused($transcriptFocused)
        .onKeyPress { press in handleKey(press) }
    }

    /// Enabled cut whose range covers word `index`, if any.
    private func cutContaining(_ index: Int) -> ReviewCutState? {
        appState.reviewCuts.first {
            $0.enabled && index >= $0.removeStartIndex && index <= $0.removeEndIndex
        }
    }

    @ViewBuilder
    private func wordView(_ i: Int) -> some View {
        let token = appState.transcript[i]
        let cut = cutContaining(i)
        let inCut = cut != nil
        let isActive = cut?.opId == activeCutId && inCut
        let isAnchor = selectionAnchor == i && !inCut

        Text(token.word)
            .font(.system(size: 15))
            .foregroundStyle(inCut ? Theme.danger : Theme.ink)
            .strikethrough(inCut, color: Theme.danger)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(wordFill(inCut: inCut, isActive: isActive, isAnchor: isAnchor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .stroke(isAnchor ? Theme.indigo : Color.clear, lineWidth: 1)
            )
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: WordFrameKey.self,
                        value: [i: g.frame(in: .named("tx"))]
                    )
                }
            )
            .contentShape(Rectangle())
            .onTapGesture { handleWordTap(i) }
    }

    private func wordFill(inCut: Bool, isActive: Bool, isAnchor: Bool) -> Color {
        if inCut { return Theme.danger.opacity(isActive ? 0.20 : 0.10) }
        if isAnchor { return Theme.wash }
        return .clear
    }

    /// Handle a tap on transcript word `i`.
    ///
    /// - Shift-click creates a manual cut from the anchored word (or this word
    ///   if no anchor) through this word, then makes it active.
    /// - A plain click on a word inside a cut selects that cut for editing.
    /// - A plain click on a free word anchors the start of a new selection.
    private func handleWordTap(_ i: Int) {
        transcriptFocused = true

        if NSEvent.modifierFlags.contains(.shift) {
            let start = selectionAnchor ?? i
            if let id = appState.createManualCut(from: start, to: i) {
                activeCutId = id
            }
            selectionAnchor = nil
            return
        }

        if let cut = cutContaining(i) {
            activeCutId = cut.opId
            selectionAnchor = nil
        } else {
            selectionAnchor = i
        }
    }

    // MARK: - Handles

    @ViewBuilder
    private var handleOverlay: some View {
        if let cut = activeCut,
            cut.enabled,
            let startFrame = wordFrames[cut.removeStartIndex],
            let endFrame = wordFrames[cut.removeEndIndex]
        {
            let hitWidth = boundaryHitWidth(startFrame: startFrame, endFrame: endFrame)
            // Leading edge of the first removed word.
            BoundaryHandle(
                boundaryX: startFrame.minX,
                top: startFrame.minY,
                height: startFrame.height,
                hitWidth: hitWidth
            ) { value in
                if let idx = nearestWordIndex(to: value.location) {
                    appState.adjustCutStart(cut.opId, to: idx)
                }
            }
            // Trailing edge of the last removed word.
            BoundaryHandle(
                boundaryX: endFrame.maxX,
                top: endFrame.minY,
                height: endFrame.height,
                hitWidth: hitWidth
            ) { value in
                if let idx = nearestWordIndex(to: value.location) {
                    appState.adjustCutEnd(cut.opId, to: idx)
                }
            }
        }
    }

    /// Resting hit width for the boundary handles. Grows the grab target well
    /// beyond the visible bar so it's easy to land on, but clamps it so the two
    /// handles never meaningfully overlap when the cut spans only a few short
    /// words on a single line. Handles on different lines never overlap, so they
    /// always get the full target.
    private func boundaryHitWidth(startFrame: CGRect, endFrame: CGRect) -> CGFloat {
        let desired: CGFloat = 30
        let sameLine = abs(startFrame.minY - endFrame.minY) < 1
        guard sameLine else { return desired }
        let gap = endFrame.maxX - startFrame.minX
        return min(desired, max(gap, 12))
    }

    /// Index of the transcript word whose frame center is nearest `point`.
    private func nearestWordIndex(to point: CGPoint) -> Int? {
        var best: Int?
        var bestDist = CGFloat.infinity
        for (index, rect) in wordFrames {
            let dx = rect.midX - point.x
            let dy = rect.midY - point.y
            let dist = dx * dx + dy * dy
            if dist < bestDist {
                bestDist = dist
                best = index
            }
        }
        return best
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let cut = activeCut else { return .ignored }
        let toStart = press.modifiers.contains(.option)
        switch press.key {
        case .leftArrow:
            if toStart {
                appState.adjustCutStart(cut.opId, to: cut.removeStartIndex - 1)
            } else {
                appState.adjustCutEnd(cut.opId, to: cut.removeEndIndex - 1)
            }
            return .handled
        case .rightArrow:
            if toStart {
                appState.adjustCutStart(cut.opId, to: cut.removeStartIndex + 1)
            } else {
                appState.adjustCutEnd(cut.opId, to: cut.removeEndIndex + 1)
            }
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Boundary handle

/// A draggable boundary handle for resizing a cut. Owns its own hover state so
/// it can grow + brighten and swap to a left-right resize cursor when the
/// pointer is over it, making the thin bar much easier to find and grab.
///
/// Uses `.offset` (not `.position`) so its drawn shape *and* its hit region move
/// to the boundary — keeping the two handles from each grabbing the whole
/// transcript. The hit region (`hitWidth`) is intentionally far wider than the
/// visible bar; its size is fixed regardless of hover so the grab target never
/// shifts under the cursor.
private struct BoundaryHandle: View {
    let boundaryX: CGFloat
    let top: CGFloat
    let height: CGFloat
    let hitWidth: CGFloat
    let onDrag: (DragGesture.Value) -> Void

    @State private var hovering = false

    var body: some View {
        let barHeight = max(18, height + 6)
        let color = hovering ? Theme.indigoHover : Theme.indigo
        return ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: hovering ? 4 : 3, height: barHeight)
            Circle()
                .fill(color)
                .frame(width: hovering ? 14 : 11, height: hovering ? 14 : 11)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .offset(y: -barHeight / 2)
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .frame(width: hitWidth, height: barHeight + 11)
        .contentShape(Rectangle())
        .offset(x: boundaryX - hitWidth / 2, y: top - 5.5)
        .onHover { inside in
            hovering = inside
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .onDisappear {
            if hovering {
                NSCursor.pop()
                hovering = false
            }
        }
        .gesture(
            DragGesture(coordinateSpace: .named("tx"))
                .onChanged(onDrag)
        )
    }
}

// MARK: - Word frame capture

private struct WordFrameKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Flow layout

/// A simple line-wrapping layout: places subviews left-to-right, wrapping to a
/// new line when the next subview would overflow the proposed width.
struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.replacingUnspecifiedDimensions().width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sv.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview {
    TranscriptReviewView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
