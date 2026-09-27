import AppKit
import OllamaKit
import SwiftUI

@main
struct OllamaGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var app: AppModel { .shared }

    var body: some Scene {
        Window("Ollama GUI", id: "main") {
            ContentView()
                .frame(minWidth: 880, minHeight: 540)
        }
        .defaultSize(width: 1320, height: 800)
        .commands {
            AppCommands(app: app)
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(isInserted: Bindable(app.settings).showMenuBarExtra) {
            MenuBarContent()
        } label: {
            Image(systemName: app.running.isEmpty ? "square.stack.3d.up" : "square.stack.3d.up.fill")
                .accessibilityLabel(Text("Ollama GUI"))
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the menu bar when the menu bar item is enabled.
        !(UserDefaults.standard.object(forKey: "showMenuBarExtra") as? Bool ?? true)
    }
}

struct AppCommands: Commands {
    let app: AppModel

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()

        CommandGroup(replacing: .newItem) {
            Button("Pull Model…") {
                app.presentPullSheet()
            }
            .keyboardShortcut("n")
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) {
                    app.section = section
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }

        CommandMenu("Models") {
            Button("Refresh") {
                Task { await app.refresh(forceModels: true) }
            }
            .keyboardShortcut("r")

            Button("Check for Updates") {
                Task { await app.checkForUpdates() }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!app.connection.isConnected || app.isCheckingUpdates)

            Divider()

            Button("Chat") {
                if let model = app.selectedModel { app.openPlayground(with: model.name) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(app.selectedModel?.canChat != true)

            Button("Duplicate…") {
                if let model = app.selectedModel { app.copyRequest = CopyRequest(source: model.name, mode: .duplicate) }
            }
            .keyboardShortcut("d")
            .disabled(app.selectedModel == nil)

            Button("Rename…") {
                if let model = app.selectedModel { app.copyRequest = CopyRequest(source: model.name, mode: .rename) }
            }
            .disabled(app.selectedModel == nil)

            Button("Customize…") {
                if let model = app.selectedModel { app.createRequest = CreateRequest(base: model.name) }
            }
            .disabled(app.selectedModel.map { $0.isCloud || !$0.canChat } ?? true)

            Button("Delete…") {
                app.requestDelete(Array(app.modelSelection))
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(app.modelSelection.isEmpty || app.section != .models)

            Divider()

            Button("Unload All Models") {
                Task { await app.unloadAll() }
            }
            .disabled(app.running.isEmpty)
        }
    }
}

extension SidebarSection {
    var title: LocalizedStringKey {
        switch self {
        case .models: LocalizedStringKey("Models")
        case .running: LocalizedStringKey("Running")
        case .downloads: LocalizedStringKey("Downloads")
        case .discover: LocalizedStringKey("Discover")
        case .playground: LocalizedStringKey("Playground")
        }
    }

    var systemImage: String {
        switch self {
        case .models: "square.stack.3d.up"
        case .running: "memorychip"
        case .downloads: "arrow.down.circle"
        case .discover: "globe"
        case .playground: "text.bubble"
        }
    }
}
