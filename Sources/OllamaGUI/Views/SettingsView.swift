import OllamaKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ServersSettingsView()
                .tabItem { Label("Servers", systemImage: "server.rack") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 460)
    }
}

private struct GeneralSettingsView: View {
    private var app: AppModel { .shared }

    var body: some View {
        @Bindable var settings = app.settings

        Form {
            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Picker("Keep models loaded for", selection: $settings.keepAliveSeconds) {
                    ForEach(KeepAliveOption.choices, id: \.self) { seconds in
                        Text(verbatim: KeepAliveOption.title(for: seconds)).tag(seconds)
                    }
                }
                Text("Applies when you load a model or chat in the Playground. Models are never kept in memory indefinitely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Refresh status every", selection: $settings.refreshInterval) {
                    ForEach(RefreshOption.choices, id: \.self) { seconds in
                        Text(verbatim: KeepAliveOption.title(for: Int(seconds))).tag(seconds)
                    }
                }
                Toggle("Check for model updates at launch", isOn: $settings.checkUpdatesOnLaunch)
                Toggle("Show in menu bar", isOn: $settings.showMenuBarExtra)
            }
            Section {
                LabeledContent("Version") {
                    Text(verbatim: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                }
                LabeledContent {
                    Link(destination: URL(string: "https://github.com/Hugo291/ollama-gui")!) {
                        Text(verbatim: "github.com/Hugo291/ollama-gui")
                    }
                } label: {
                    Text("Source Code")
                }
            } footer: {
                Text("An independent open-source project, not affiliated with Ollama.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ServersSettingsView: View {
    private var app: AppModel { .shared }
    @State private var selection: ServerConfig.ID?

    var body: some View {
        @Bindable var settings = app.settings

        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: server.name)
                                Text(verbatim: server.displayURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if server.id == settings.selectedServerID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .help(Text("Current server"))
                            }
                        }
                        .tag(server.id)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))

                HStack(spacing: 0) {
                    Button {
                        let server = ServerConfig(name: String(localized: "New Server"), address: "http://192.168.1.20:11434")
                        settings.servers.append(server)
                        selection = server.id
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 20)
                    }
                    .help(Text("Add a server"))
                    Divider()
                        .frame(height: 16)
                    Button {
                        guard let selection else { return }
                        let wasCurrent = selection == settings.selectedServerID
                        settings.servers.removeAll { $0.id == selection }
                        self.selection = settings.servers.first?.id
                        if wasCurrent { app.serverDidChange() }
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 24, height: 20)
                    }
                    .help(Text("Remove the selected server"))
                    .disabled(selection == nil || settings.servers.count < 2)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 230)

            if let server = settings.servers.first(where: { $0.id == selection }) {
                ServerEditor(server: server)
                    .id(server.id)
            } else {
                Text("Select a server to edit it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .onAppear { selection = selection ?? settings.selectedServerID }
    }
}

/// Edits a copy of a server: nothing changes until Save, so the app never talks to a
/// half-typed address.
private struct ServerEditor: View {
    private var app: AppModel { .shared }
    let server: ServerConfig

    @State private var name: String
    @State private var address: String
    @State private var testResult: TestResult?

    private enum TestResult: Equatable {
        case testing
        case success(String)
        case failure(String)
    }

    init(server: ServerConfig) {
        self.server = server
        _name = State(initialValue: server.name)
        _address = State(initialValue: server.address)
    }

    private var draft: ServerConfig {
        ServerConfig(id: server.id, name: name.trimmingCharacters(in: .whitespaces), address: address.trimmingCharacters(in: .whitespaces))
    }

    private var hasChanges: Bool { draft.name != server.name || draft.address != server.address }

    var body: some View {
        let isCurrent = server.id == app.settings.selectedServerID
        Form {
            TextField("Name", text: $name)
                .onSubmit(save)
            TextField("Address", text: $address, prompt: Text(verbatim: "http://127.0.0.1:11434"))
                .onSubmit(save)
            if draft.isValid {
                LabeledContent("Connects to") {
                    Text(verbatim: draft.displayURL)
                        .textSelection(.enabled)
                }
            } else {
                Text("This isn't a valid address.")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Test Connection", action: test)
                    .disabled(!draft.isValid || testResult == .testing)
                switch testResult {
                case .testing:
                    ProgressView()
                        .controlSize(.small)
                case .success(let version):
                    Label {
                        Text("Connected · Ollama \(version)")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                case .failure(let message):
                    Label {
                        Text(verbatim: message)
                            .lineLimit(2)
                    } icon: {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                    }
                case nil:
                    EmptyView()
                }
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid || !hasChanges)
            }

            if isCurrent {
                Button("Reconnect") { app.serverDidChange() }
            } else {
                Button("Use This Server") { app.selectServer(server.id) }
                    .disabled(!server.isValid || hasChanges)
            }
        }
        .formStyle(.grouped)
        .onChange(of: address) { _, _ in testResult = nil }
    }

    private func save() {
        guard draft.isValid, hasChanges else { return }
        let settings = app.settings
        guard let index = settings.servers.firstIndex(where: { $0.id == server.id }) else { return }
        let addressChanged = settings.servers[index].url != draft.url
        settings.servers[index] = draft
        if addressChanged, server.id == settings.selectedServerID {
            app.serverDidChange()
        }
    }

    private func test() {
        let url = draft.url
        testResult = .testing
        Task {
            let result: TestResult
            do {
                result = .success(try await OllamaClient(baseURL: url).version())
            } catch {
                result = .failure(error.localizedDescription)
            }
            // The address changed during the test: the result is about another address.
            guard draft.url == url else { return }
            testResult = result
        }
    }
}
