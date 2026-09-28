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
        .frame(width: 600, height: 400)
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
        }
        .formStyle(.grouped)
    }
}

private struct ServersSettingsView: View {
    private var app: AppModel { .shared }
    @State private var selection: ServerConfig.ID?
    @State private var testResult: TestResult?

    private enum TestResult: Equatable {
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var settings = app.settings

        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(settings.servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: server.name)
                                Text(verbatim: server.url.absoluteString)
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
                        let server = ServerConfig(name: String(localized: "New Server"), address: "http://192.168.1.10:11434")
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

            if let index = settings.servers.firstIndex(where: { $0.id == selection }) {
                editor(for: $settings.servers[index])
            } else {
                Text("Select a server to edit it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .onAppear { selection = selection ?? settings.selectedServerID }
        .onChange(of: selection) { _, _ in testResult = nil }
    }

    private func editor(for server: Binding<ServerConfig>) -> some View {
        let isCurrent = server.wrappedValue.id == app.settings.selectedServerID
        return Form {
            TextField("Name", text: server.name)
            TextField("Address", text: server.address, prompt: Text(verbatim: "http://127.0.0.1:11434"))
                .onSubmit {
                    if isCurrent { app.serverDidChange() }
                }
            if server.wrappedValue.isValid {
                LabeledContent("Connects to") {
                    Text(verbatim: server.wrappedValue.url.absoluteString)
                        .textSelection(.enabled)
                }
            } else {
                Text("This isn't a valid address.")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Test Connection") {
                    test(server.wrappedValue)
                }
                .disabled(!server.wrappedValue.isValid || testResult == .testing)
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
            }

            if isCurrent {
                Button("Reconnect") { app.serverDidChange() }
            } else {
                Button("Use This Server") { app.selectServer(server.wrappedValue.id) }
                    .disabled(!server.wrappedValue.isValid)
            }
        }
        .formStyle(.grouped)
    }

    private func test(_ server: ServerConfig) {
        testResult = .testing
        Task {
            do {
                let version = try await OllamaClient(baseURL: server.url).version()
                testResult = .success(version)
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }
}
