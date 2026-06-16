import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings

    @State private var isTargeted = false
    @State private var isLoadingMetadata = false

    private var isReady: Bool { appState.metadata != nil }

    var body: some View {
        AppShell {
            if isReady {
                fileSidebar
            } else {
                StatusPanelView()
            }
        } content: {
            if isReady {
                readyContent
            } else {
                dropContent
            }
        }
    }

    // MARK: - Sidebar (ready state)

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader("Selected file")
            if let url = appState.droppedFile {
                sidebarRow(label: "Name", value: url.lastPathComponent)
            }
            if let md = appState.metadata {
                sidebarRow(label: "Duration", value: Formatters.duration(md.durationSec))
                sidebarRow(label: "Size", value: Formatters.bytes(md.sizeBytes))
                if let w = md.width, let h = md.height {
                    sidebarRow(label: "Resolution", value: "\(w)×\(h)")
                }
            }
            Spacer(minLength: 16)
            Text("Detection and quality defaults live in Settings (⌘,).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
        }
    }

    private func sidebarRow(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 10)
    }

    // MARK: - Drop content (empty / loading state)

    private var dropContent: some View {
        VStack(spacing: 20) {
            Spacer()
            dropZone
                .frame(maxWidth: 520)
            Text("SmartCut will detect silence and AI-flagged retakes, then let you review each cut.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if let error = appState.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .topTrailing) {
            Theme.halo(colorScheme)
                .frame(width: 720, height: 520)
                .offset(x: 160, y: -140)
                .allowsHitTesting(false)
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.indigo)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.wash)
                )
            Text("Drop a video here")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.ink)
            Text("Supported: .mp4, .mov, .mkv, .webm")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Text("or").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            Button(action: openFilePicker) {
                Text("Choose file…")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.scPrimary)
            .disabled(isLoadingMetadata)

            if isLoadingMetadata {
                ProgressView().controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(isTargeted ? Theme.wash : Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(
                            isTargeted ? Theme.indigo : Theme.borderStrong,
                            style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                        )
                )
        )
        .onDrop(of: [UTType.movie, UTType.video, UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Ready content

    private var readyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                readyHeader
                if !appState.config.hasRequiredSecrets {
                    credentialsBanner
                }
                fileCard
                outputField
                actionRow
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(alignment: .topTrailing) {
            Theme.halo(colorScheme)
                .frame(width: 720, height: 520)
                .offset(x: 160, y: -140)
                .allowsHitTesting(false)
        }
    }

    private var readyHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("READY TO CUT")
                .font(.system(size: 10, weight: .regular))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Text("Review & start")
                .font(.system(size: 28, weight: .light))
                .gradientTitle(colorScheme)
            Text("Your video is loaded. Confirm where the result should be saved, then start the smart cut. Detection settings use your saved defaults.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.bodyText)
        }
    }

    private var credentialsBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.warn)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Add your API credentials before you can start")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text("SmartCut needs a Cloudflare account ID and API token to detect retakes.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.bodyText)
            }
            Spacer(minLength: 0)
            Button("Open Settings…") {
                appState.settingsTab = .credentials
                openSettings()
            }
            .buttonStyle(.scNeutralCompact)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.warn.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .stroke(Theme.warn.opacity(0.45), lineWidth: 1)
                )
        )
    }

    private var fileCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "video.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.indigo)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.wash)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(appState.droppedFile?.lastPathComponent ?? "")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(metadataLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button("Choose different…") { appState.resetToDrop() }
                .buttonStyle(.scGhostCompact)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
    }

    private var metadataLine: String {
        guard let md = appState.metadata else { return "—" }
        var parts: [String] = [Formatters.duration(md.durationSec)]
        if let w = md.width, let h = md.height { parts.append("\(w)×\(h)") }
        if let c = md.codec { parts.append(c) }
        parts.append(Formatters.bytes(md.sizeBytes))
        return parts.joined(separator: " · ")
    }

    private var outputField: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 8) {
            Text("Save output to")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink)
            HStack(spacing: 8) {
                TextField("Output path", text: $appState.options.output)
                    .scInputField()
                    .frame(maxWidth: 380)
                Button("Browse…") { browseForOutput() }
                    .buttonStyle(.scNeutralCompact)
                Spacer(minLength: 0)
            }
            Text("Defaults next to the source file, or to your default output folder from Settings → Output.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: { Task { await appState.startProcessing() } }) {
                Text("Start smart cut").frame(minWidth: 120)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.scPrimary)
            .disabled(!appState.config.hasRequiredSecrets)

            Button("Cancel") { appState.resetToDrop() }
                .buttonStyle(.scSecondary)

            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - File pick / drop handling

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await load(url: url) }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let typeIdentifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return false }
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            let resolved: URL?
            if let url = item as? URL {
                resolved = url
            } else if let data = item as? Data {
                resolved = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                resolved = nil
            }
            guard let url = resolved else { return }
            Task { @MainActor in await load(url: url) }
        }
        return true
    }

    @MainActor
    private func load(url: URL) async {
        isLoadingMetadata = true
        defer { isLoadingMetadata = false }
        await appState.handleDrop(url)
    }

    private func browseForOutput() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        if !appState.options.output.isEmpty {
            let url = URL(fileURLWithPath: appState.options.output)
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        if panel.runModal() == .OK, let url = panel.url {
            appState.options.output = url.path
        }
    }
}

#Preview {
    DropZoneView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
