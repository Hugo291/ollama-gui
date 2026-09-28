import OllamaKit
import SwiftUI

struct SidebarView: View {
    private var app: AppModel { .shared }

    var body: some View {
        @Bindable var app = app

        List(selection: $app.section) {
            Section("Library") {
                row(.models, badge: app.models.count)
                row(.running, badge: app.running.count)
                row(.downloads, badge: app.downloads.activeCount)
            }
            Section("Explore") {
                row(.discover)
                row(.playground)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ServerStatusView()
                .padding(10)
        }
    }

    private func row(_ section: SidebarSection, badge: Int = 0) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(badge)
            .tag(section)
    }
}

/// Connection status and server switcher at the bottom of the sidebar.
struct ServerStatusView: View {
    private var app: AppModel { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(connection: app.connection)
                app.connection.summary
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .help(helpText)

            Menu {
                Picker("Server", selection: serverSelection) {
                    ForEach(app.settings.servers) { server in
                        Text(verbatim: server.name).tag(server.id)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                SettingsLink {
                    Text("Manage Servers…")
                }
            } label: {
                Label {
                    Text(verbatim: app.settings.currentServer.name)
                } icon: {
                    Image(systemName: "server.rack")
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if case .unreachable = app.connection {
                HStack {
                    if app.canStartLocalOllama {
                        Button("Start Ollama") { app.startLocalOllama() }
                    }
                    Button("Retry") {
                        Task { await app.refresh(forceModels: true) }
                    }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var serverSelection: Binding<UUID> {
        Binding(get: { app.settings.selectedServerID }, set: { app.selectServer($0) })
    }

    private var helpText: String {
        if case .unreachable(let message) = app.connection { return message }
        return app.settings.currentServer.displayURL
    }
}
