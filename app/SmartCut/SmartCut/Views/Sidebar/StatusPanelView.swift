import SwiftUI

/// Tool/setup status panel for the sidebar on the Drop screen.
/// Shows whether ffmpeg, whisper, and the API key are configured.
/// Phase 4 wires this up to real probes; for now it shows the assumed-OK
/// state since the v1 prereqs are documented in PLAN.md.
struct StatusPanelView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader("Status")
            row(label: "ffmpeg", value: "ready", tint: .green)
            row(label: "whisper", value: "base.en", tint: .secondary)
            row(label: "API key", value: "configured", tint: .green)
        }
    }

    private func row(label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 4)
            Text(value).font(.system(size: 11)).foregroundStyle(tint)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 10)
    }
}

/// Reusable shell: sidebar (left, 240 pt) + content (right). Every screen
/// other than `.drop` re-uses this; `.drop` substitutes a "Recent files"
/// + status panel as the sidebar content via `sidebar:` slot.
struct AppShell<Sidebar: View, Content: View>: View {
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                sidebar
                Spacer(minLength: 0)
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 6)
            .frame(width: 240)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
