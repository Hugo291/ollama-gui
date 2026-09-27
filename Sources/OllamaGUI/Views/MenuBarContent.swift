import AppKit
import OllamaKit
import SwiftUI

/// Content of the menu bar item: loaded models and quick actions.
struct MenuBarContent: View {
    private var app: AppModel { .shared }
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(verbatim: app.settings.currentServer.name)
        app.connection.summary

        Divider()

        if app.running.isEmpty {
            Text("No models in memory")
        } else {
            Section("In Memory") {
                ForEach(app.running) { model in
                    Menu {
                        Text(verbatim: model.processorLabel)
                        if let expiresAt = model.expiresAt, !model.staysLoaded {
                            Text("Unloads at \(expiresAt.formatted(date: .omitted, time: .shortened))")
                        }
                        Divider()
                        if app.model(named: model.name)?.canChat == true {
                            Button("Chat") {
                                app.openPlayground(with: model.name)
                                showMainWindow()
                            }
                        }
                        Button("Unload") {
                            Task { await app.unload(model.name) }
                        }
                    } label: {
                        Text(verbatim: "\(model.name) — \(Format.bytes(model.size))")
                    }
                }
            }
            Button("Unload All") {
                Task { await app.unloadAll() }
            }
        }

        let active = app.downloads.activeTasks
        if !active.isEmpty {
            Divider()
            Section("Downloads") {
                ForEach(active) { download in
                    Button {
                        app.section = .downloads
                        showMainWindow()
                    } label: {
                        if let fraction = download.fractionCompleted {
                            Text(verbatim: "\(download.modelName) — \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                        } else {
                            Text(verbatim: download.modelName)
                        }
                    }
                }
            }
        }

        Divider()

        Button("Open Ollama GUI") {
            showMainWindow()
        }
        .keyboardShortcut("o")
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit Ollama GUI") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}
