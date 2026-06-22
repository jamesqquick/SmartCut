import AppKit
import AVFoundation
import AVKit
import SwiftUI

struct TranscriptReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @State private var audio = AudioPlayer()
    @State private var video = VideoPreviewPlayer()
    @State private var inspectOpen = false
    @State private var selectionAnchor: Int?
    @State private var wordFrames: [Int: CGRect] = [:]
    @FocusState private var transcriptFocused: Bool

    private var cuts: [ReviewCutState] { appState.reviewCuts }
    private var currentIndex: Int { appState.currentCutIndex }
    private var currentCut: ReviewCutState? {
        guard cuts.indices.contains(currentIndex) else { return nil }
        return cuts[currentIndex]
    }

    var body: some View {
        AppShell {
            sidebarContent
        } content: {
            mainContent
        }
        .onAppear {
            appState.prefetchVideoPreview(forCutAt: 1)
        }
        .onChange(of: currentIndex) {
            inspectOpen = false
            audio.stop()
            video.stop()
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepperView()
            SidebarSectionHeader("Cuts")
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(appState.reviewedCount), total: max(1, Double(cuts.count)))
                    .tint(appState.allReviewed ? Theme.good : Theme.indigo)
                    .animation(.easeOut(duration: 0.2), value: appState.reviewedCount)
                Text("\(appState.reviewedCount) of \(cuts.count) reviewed")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(cuts.enumerated()), id: \.element.opId) { i, cut in
                            cutRow(index: i, cut: cut).id(cut.opId)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .onChange(of: currentIndex) { _, _ in
                    if let opId = currentCut?.opId {
                        withAnimation { proxy.scrollTo(opId, anchor: .center) }
                    }
                }
            }
        }
    }

    private func cutRow(index: Int, cut: ReviewCutState) -> some View {
        let isActive = index == currentIndex
        return Button {
            appState.navigateTo(index)
            transcriptFocused = true
        } label: {
            HStack(spacing: 8) {
                Circle().fill(pipColor(cut)).frame(width: 7, height: 7)
                Text("Cut \(index + 1)")
                    .font(.system(size: 12))
                    .foregroundStyle(cut.status == .rejected ? Theme.muted : Theme.ink)
                Spacer(minLength: 4)
                Group {
                    switch cut.status {
                    case .approved:
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.good)
                    case .rejected:
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.muted)
                    case .pending:
                        Text(Formatters.shortDuration(appState.estimatedDuration(cut)))
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.muted)
                            .monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(isActive ? Theme.wash : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(isActive ? Theme.indigo : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func pipColor(_ cut: ReviewCutState) -> Color {
        if cut.source == .manual { return Theme.indigo }
        if let conf = cut.op?.confidence, conf < 65 { return Theme.warn }
        return Theme.good
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            transcriptPane
            Divider().background(Theme.border)
            actionBar
            if inspectOpen { inspectPanel }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Transcript

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
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
                .padding(.top, 24)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .focusable()
            .focused($transcriptFocused)
            .onKeyPress { press in handleKey(press) }
            .onChange(of: currentIndex) { _, _ in
                scrollToCurrentCut(proxy: proxy)
            }
            .onAppear {
                transcriptFocused = true
                scrollToCurrentCut(proxy: proxy)
            }
        }
    }

    private func scrollToCurrentCut(proxy: ScrollViewProxy) {
        guard let opId = currentCut?.opId else { return }
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(opId, anchor: .center) }
    }

    private func cutContaining(_ index: Int) -> ReviewCutState? {
        appState.reviewCuts.first {
            index >= $0.removeStartIndex && index <= $0.removeEndIndex
        }
    }

    @ViewBuilder
    private func wordView(_ i: Int) -> some View {
        let token = appState.transcript[i]
        let cut = cutContaining(i)
        let inCut = cut != nil
        let isCurrent = cut?.opId == currentCut?.opId
        let isRejected = cut?.status == .rejected
        let isAnchor = selectionAnchor == i && !inCut

        ZStack {
            Text(token.word)
                .font(.system(size: 15))
                .foregroundStyle(inCut ? (isRejected ? Theme.muted : Theme.danger) : Theme.ink)
                .strikethrough(inCut && !isRejected, color: Theme.danger)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(wordFill(inCut: inCut, isCurrent: isCurrent,
                                      isRejected: isRejected, isAnchor: isAnchor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .stroke(isAnchor ? Theme.indigo : Color.clear, lineWidth: 1)
                )
        }
        .id((cut?.removeStartIndex == i) ? cut?.opId : nil)
        .background(GeometryReader { g in
            Color.clear.preference(key: WordFrameKey.self,
                                   value: [i: g.frame(in: .named("tx"))])
        })
        .contentShape(Rectangle())
        .onTapGesture { handleWordTap(i) }
    }

    private func wordFill(inCut: Bool, isCurrent: Bool, isRejected: Bool, isAnchor: Bool) -> Color {
        if inCut {
            if isRejected { return Theme.border.opacity(0.4) }
            return Theme.danger.opacity(isCurrent ? 0.20 : 0.10)
        }
        if isAnchor { return Theme.wash }
        return .clear
    }

    private func handleWordTap(_ i: Int) {
        transcriptFocused = true
        if NSEvent.modifierFlags.contains(.shift) {
            let start = selectionAnchor ?? i
            if let id = appState.createManualCut(from: start, to: i),
               let idx = appState.reviewCuts.firstIndex(where: { $0.opId == id }) {
                appState.navigateTo(idx)
            }
            selectionAnchor = nil
            return
        }
        if let cut = cutContaining(i),
           let idx = appState.reviewCuts.firstIndex(where: { $0.opId == cut.opId }) {
            appState.navigateTo(idx)
            selectionAnchor = nil
        } else {
            selectionAnchor = i
        }
    }

    // MARK: - Handles

    @ViewBuilder
    private var handleOverlay: some View {
        if let cut = currentCut,
           cut.status != .rejected,
           let startFrame = wordFrames[cut.removeStartIndex],
           let endFrame = wordFrames[cut.removeEndIndex] {
            let hitWidth = boundaryHitWidth(startFrame: startFrame, endFrame: endFrame)
            BoundaryHandle(boundaryX: startFrame.minX, top: startFrame.minY,
                           height: startFrame.height, hitWidth: hitWidth) { value in
                if let idx = nearestWordIndex(to: value.location) {
                    appState.adjustCutStart(cut.opId, to: idx)
                }
            }
            BoundaryHandle(boundaryX: endFrame.maxX, top: endFrame.minY,
                           height: endFrame.height, hitWidth: hitWidth) { value in
                if let idx = nearestWordIndex(to: value.location) {
                    appState.adjustCutEnd(cut.opId, to: idx)
                }
            }
        }
    }

    private func boundaryHitWidth(startFrame: CGRect, endFrame: CGRect) -> CGFloat {
        let desired: CGFloat = 30
        let sameLine = abs(startFrame.minY - endFrame.minY) < 1
        guard sameLine else { return desired }
        return min(desired, max(endFrame.maxX - startFrame.minX, 12))
    }

    private func nearestWordIndex(to point: CGPoint) -> Int? {
        var best: Int?; var bestDist = CGFloat.infinity
        for (index, rect) in wordFrames {
            let d = (rect.midX - point.x) * (rect.midX - point.x) + (rect.midY - point.y) * (rect.midY - point.y)
            if d < bestDist { bestDist = d; best = index }
        }
        return best
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 0) {
            if appState.allReviewed {
                renderGate
            } else {
                if let cut = currentCut {
                    HStack(spacing: 8) {
                        chipLabel(cut)
                        Text("removes \(Formatters.shortDuration(appState.estimatedDuration(cut)))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.leading, 16)
                }
                Spacer()
                HStack(spacing: 8) {
                    audioButton
                    videoButton
                    Divider().frame(height: 22).padding(.horizontal, 4)
                    rejectButton
                    approveButton
                }
                .padding(.trailing, 16)
            }
        }
        .frame(height: 54)
        .background(Theme.card)
    }

    private var renderGate: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.good)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text("All cuts reviewed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(
                    "\(appState.enabledCutCount) of \(appState.reviewCuts.count) cuts applied"
                    + " · ~\(Formatters.shortDuration(appState.reviewSavedEstimate)) saved"
                )
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Cancel") { Task { await appState.cancel() } }
                .buttonStyle(.scSecondaryCompact)
            Button(action: { Task { await appState.applyReview() } }) {
                Label("Render", systemImage: "film.stack").frame(minWidth: 80)
            }
            .buttonStyle(.scPrimary)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chipLabel(_ cut: ReviewCutState) -> some View {
        let label: String = cut.source == .manual ? "Manual" : "AI · \(Int(cut.op?.confidence ?? 0))%"
        let color: Color = cut.source == .manual ? Theme.indigo :
            ((cut.op?.confidence ?? 100) < 65 ? Theme.warn : Theme.indigo)
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
    }

    private func actionButton(systemImage: String, label: String, color: Color = Theme.bodyText,
                               isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? color : Theme.bodyText)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(isActive ? color.opacity(0.12) : Theme.elevated)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(isActive ? color.opacity(0.4) : Theme.borderStrong, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    private var audioButton: some View {
        let isPlaying = audio.isPlaying, isLoading = audio.isLoading
        return Button {
            if isPlaying || isLoading { audio.stop() } else { playAudioPreview() }
        } label: {
            Label(isPlaying ? "Stop" : "Audio", systemImage: isPlaying ? "stop.fill" : "speaker.wave.2")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isPlaying ? Theme.good : Theme.bodyText)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(isPlaying ? Theme.good.opacity(0.12) : Theme.elevated)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(isPlaying ? Theme.good.opacity(0.4) : Theme.borderStrong, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("a", modifiers: [])
        .help("Preview audio across the cut (A)")
    }

    private var videoButton: some View {
        actionButton(systemImage: inspectOpen ? "video.fill" : "video", label: "Video",
                     color: Theme.indigo, isActive: inspectOpen) { toggleInspect() }
        .keyboardShortcut("v", modifiers: [])
        .help("Watch the resulting video clip (V)")
    }

    private var rejectButton: some View {
        actionButton(systemImage: "xmark", label: "Reject", color: Theme.danger,
                     isActive: currentCut?.status == .rejected) {
            appState.rejectCurrent(); inspectOpen = false; audio.stop(); video.stop()
        }
        .keyboardShortcut(.delete, modifiers: [])
        .help("Keep these words — reject the cut (Del)")
    }

    private var approveButton: some View {
        actionButton(systemImage: "checkmark", label: "Approve", color: Theme.good,
                     isActive: currentCut?.status == .approved) {
            appState.approveCurrent(); inspectOpen = false; audio.stop(); video.stop()
        }
        .keyboardShortcut(.return, modifiers: [])
        .help("Remove these words — approve the cut (Return)")
    }

    private func playAudioPreview() {
        guard let cut = currentCut, let input = appState.droppedFile,
              let duration = appState.metadata?.durationSec else { return }
        let key = "preview-\(cut.opId)"
        let (focusStart, focusEnd) = appState.sourceTimes(for: cut)
        guard focusEnd > focusStart else { return }
        let cuts = appState.cutsAsSegments(including: cut.opId)
        let silences = appState.silenceSegments
        let leadInMs = appState.options.leadInMs
        let tailOutMs = appState.options.tailOutMs
        let sidecar = appState.sidecar!
        audio.play(key: key) {
            let clip = try await sidecar.extractEditedPreview(
                input: input, duration: duration,
                focusStart: focusStart, focusEnd: focusEnd,
                padSec: 2.5, tailSec: 2.5,
                leadInMs: leadInMs, tailOutMs: tailOutMs,
                cuts: cuts, silences: silences)
            return URL(fileURLWithPath: clip.path)
        }
    }

    private func toggleInspect() {
        inspectOpen.toggle()
        if inspectOpen { playVideoPreview() } else { video.stop() }
    }

    private func playVideoPreview() {
        guard let cut = currentCut, let input = appState.droppedFile,
              let duration = appState.metadata?.durationSec else { return }
        let key = "video-\(cut.opId)"
        let (focusStart, focusEnd) = appState.sourceTimes(for: cut)
        guard focusEnd > focusStart else { return }
        let cached = appState.videoPreviews[cut.opId]
        let cuts = appState.cutsAsSegments(including: cut.opId)
        let silences = appState.silenceSegments
        let sidecar = appState.sidecar!
        video.play(key: key) {
            if let clip = cached { return URL(fileURLWithPath: clip.path) }
            let clip = try await sidecar.extractEditedVideoPreview(
                input: input, duration: duration,
                focusStart: focusStart, focusEnd: focusEnd,
                cuts: cuts, silences: silences)
            return URL(fileURLWithPath: clip.path)
        }
    }

    // MARK: - Inspect panel

    private var inspectPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(Theme.border)
            HStack(alignment: .top, spacing: 16) {
                videoPlayerView.frame(maxWidth: 380)
                if let cut = currentCut { wordTrimControls(cut: cut) }
                Spacer()
            }
            .padding(16)
            .background(Theme.card)
        }
    }

    @ViewBuilder
    private var videoPlayerView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let player = video.player {
                VideoPlayer(player: player)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            } else if video.isLoading {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.elevated).aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(ProgressView().tint(Theme.indigo))
            } else {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.elevated).aspectRatio(16 / 10, contentMode: .fit)
                    .overlay(Text("Press V to preview the resulting clip")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted))
            }
            Text("480p preview · ±2.5s around the cut point")
                .font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }

    @ViewBuilder
    private func wordTrimControls(cut: ReviewCutState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trim boundaries")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Text("Start").font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 32, alignment: .leading)
                Button("−1 word") { appState.adjustCutStart(cut.opId, to: cut.removeStartIndex - 1); if inspectOpen { playVideoPreview() } }.buttonStyle(.scNeutralCompact)
                Button("+1 word") { appState.adjustCutStart(cut.opId, to: cut.removeStartIndex + 1); if inspectOpen { playVideoPreview() } }.buttonStyle(.scNeutralCompact)
            }
            HStack(spacing: 8) {
                Text("End").font(.system(size: 11)).foregroundStyle(Theme.muted).frame(width: 32, alignment: .leading)
                Button("−1 word") { appState.adjustCutEnd(cut.opId, to: cut.removeEndIndex - 1); if inspectOpen { playVideoPreview() } }.buttonStyle(.scNeutralCompact)
                Button("+1 word") { appState.adjustCutEnd(cut.opId, to: cut.removeEndIndex + 1); if inspectOpen { playVideoPreview() } }.buttonStyle(.scNeutralCompact)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.elevated)
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1))
        )
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case KeyEquivalent("j"):
            if appState.currentCutIndex < cuts.count - 1 { appState.navigateTo(appState.currentCutIndex + 1) }
            return .handled
        case KeyEquivalent("k"):
            if appState.currentCutIndex > 0 { appState.navigateTo(appState.currentCutIndex - 1) }
            return .handled
        case .upArrow where press.modifiers.isEmpty:
            if appState.currentCutIndex > 0 { appState.navigateTo(appState.currentCutIndex - 1) }
            return .handled
        case .downArrow where press.modifiers.isEmpty:
            if appState.currentCutIndex < cuts.count - 1 { appState.navigateTo(appState.currentCutIndex + 1) }
            return .handled
        case .return where press.modifiers.isEmpty:
            appState.approveCurrent(); inspectOpen = false; audio.stop(); video.stop()
            return .handled
        case .delete where press.modifiers.isEmpty:
            appState.rejectCurrent(); inspectOpen = false; audio.stop(); video.stop()
            return .handled
        case KeyEquivalent("a") where press.modifiers.isEmpty:
            if audio.isPlaying || audio.isLoading { audio.stop() } else { playAudioPreview() }
            return .handled
        case KeyEquivalent("v") where press.modifiers.isEmpty:
            toggleInspect()
            return .handled
        case .leftArrow:
            guard let cut = currentCut else { return .ignored }
            if press.modifiers.contains(.option) { appState.adjustCutStart(cut.opId, to: cut.removeStartIndex - 1) }
            else { appState.adjustCutEnd(cut.opId, to: cut.removeEndIndex - 1) }
            return .handled
        case .rightArrow:
            guard let cut = currentCut else { return .ignored }
            if press.modifiers.contains(.option) { appState.adjustCutStart(cut.opId, to: cut.removeStartIndex + 1) }
            else { appState.adjustCutEnd(cut.opId, to: cut.removeEndIndex + 1) }
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Boundary handle

private struct BoundaryHandle: View {
    let boundaryX: CGFloat; let top: CGFloat; let height: CGFloat
    let hitWidth: CGFloat; let onDrag: (DragGesture.Value) -> Void
    @State private var hovering = false

    var body: some View {
        let barHeight = max(18, height + 6)
        let color = hovering ? Theme.indigoHover : Theme.indigo
        return ZStack {
            RoundedRectangle(cornerRadius: 2).fill(color)
                .frame(width: hovering ? 4 : 3, height: barHeight)
            Circle().fill(color)
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
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .gesture(DragGesture(coordinateSpace: .named("tx")).onChanged(onDrag))
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

struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4; var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.replacingUnspecifiedDimensions().width
        var x: CGFloat = 0; var y: CGFloat = 0; var lh: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxWidth && x > 0 { x = 0; y += lh + lineSpacing; lh = 0 }
            x += s.width + spacing; lh = max(lh, s.height)
        }
        return CGSize(width: maxWidth, height: y + lh)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0; var y: CGFloat = 0; var lh: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxWidth && x > 0 { x = 0; y += lh + lineSpacing; lh = 0 }
            sv.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing; lh = max(lh, s.height)
        }
    }
}

#Preview {
    TranscriptReviewView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
