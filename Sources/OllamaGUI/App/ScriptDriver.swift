#if DEBUG
import AppKit
import OllamaKit
import SwiftUI

/// Test driver of debug builds: runs the app behind every other window, with its own
/// settings, and plays a script. Nothing here is compiled into release builds.
///
///     OLLAMA_GUI_DEFAULTS=ollama-gui-tests \
///     OLLAMA_GUI_SHOTS=/tmp/shots \
///     OLLAMA_GUI_SCRIPT="wait:3;section:models;select:gemma3:latest;shot:models;print;quit" \
///     .build/debug/OllamaGUI
///
/// `OLLAMA_GUI_DEFAULTS` names a separate settings domain (the real settings are never
/// read or written); `OLLAMA_GUI_V2_SETTINGS` points the version 2 import at a test file.
/// Commands: `wait:seconds`, `section:name`, `select:name[,name…]`, `select-all`,
/// `search:text`, `filter:all|local|cloud|vision|tools|thinking|embedding|image`, `reveal:name`,
/// `discover-search:text`, `discover-select:library/name`, `discover-more`, `load:model`, `thinking:on|off`, `send`, `wait-reply`,
/// `delete-selection`, `cancel-dialogs`, `appearance:system|light|dark`, `size:width,height`,
/// `chat:model`, `draft:text`, `markdown-sample`, `settings[:servers|general|off]`, `shot:name`, `print`, `quit`.
@MainActor
enum ScriptDriver {
    static var script: String? { ProcessInfo.processInfo.environment["OLLAMA_GUI_SCRIPT"] }

    static var isActive: Bool { script != nil }

    /// Settings of a scripted run: a separate domain, and no import unless asked for.
    static func settings() -> AppSettings? {
        guard isActive else { return nil }
        let environment = ProcessInfo.processInfo.environment
        let suite = environment["OLLAMA_GUI_DEFAULTS"] ?? "ollama-gui-tests"
        guard let defaults = UserDefaults(suiteName: suite) else { return nil }
        let version2 = environment["OLLAMA_GUI_V2_SETTINGS"].map { URL(fileURLWithPath: $0) }
        let settings = AppSettings(defaults: defaults, version2Settings: version2)
        // Tests leave the menu bar alone.
        settings.showMenuBarExtra = false
        return settings
    }

    static func start() {
        guard let script else { return }
        // No Dock icon, no activation: the window stays behind the ones in use.
        NSApp.setActivationPolicy(.accessory)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            hideWindow()
            for command in script.split(separator: ";").map(String.init) {
                log("script: \(command)")
                await run(command)
            }
        }
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.canBecomeMain }
    }

    private static func hideWindow() {
        guard let window else { return }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior.insert(.stationary)
        window.orderBack(nil)
    }

    private static func run(_ command: String) async {
        let app = AppModel.shared
        let (name, argument) = command.split(separator: ":", maxSplits: 1).map(String.init).splitPair()
        switch name {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
        case "section":
            app.section = SidebarSection(rawValue: argument) ?? .models
        case "select":
            app.modelSelection = Set(argument.split(separator: ",").map(String.init))
        case "search":
            app.modelSearch = argument
        case "filter":
            app.modelFilter = ModelFilter(rawValue: argument) ?? .all
        case "reveal":
            app.reveal(argument)
        case "discover-search":
            app.discover.query = argument
        case "discover-select":
            app.discover.selection = argument
        case "discover-more":
            app.discover.loadMore()
        case "select-all":
            // Like ⌘A in the table: the models shown.
            app.modelSelection = Set(app.visibleModels.map(\.name))
        case "delete-selection":
            // Only opens the confirmation: scripts never delete anything.
            app.requestDelete(Array(app.modelSelection))
        case "cancel-dialogs":
            app.deleteRequest = nil
            app.copyRequest = nil
            app.createRequest = nil
            app.isPullSheetPresented = false
            NSApp.windows.forEach { window in window.sheets.forEach { window.endSheet($0) } }
        case "appearance":
            app.settings.appearance = ["light": .light, "dark": .dark][argument] ?? .system
        case "size":
            let values = argument.split(separator: ",").compactMap { Double($0) }
            if values.count == 2, let window {
                window.setContentSize(NSSize(width: values[0], height: values[1]))
            }
        case "chat":
            app.openPlayground(with: argument)
        case "draft":
            app.playground.draft = argument.replacingOccurrences(of: "\\n", with: "\n")
        case "load":
            // With the keep-alive of the settings: models never stay loaded indefinitely.
            await app.load(argument)
        case "thinking":
            app.playground.thinkingEnabled = argument != "off"
        case "send":
            let thinking = app.model(named: app.playground.modelName)?.supports(.thinking) ?? false
            app.playground.send(using: app.client, keepAlive: app.settings.keepAliveSeconds, supportsThinking: thinking)
        case "wait-reply":
            // Until the reply ends, at most two minutes.
            for _ in 0..<240 where app.playground.isGenerating {
                try? await Task.sleep(for: .milliseconds(500))
            }
        case "markdown-sample":
            app.playground.messages.append(PlaygroundMessage(role: .user, content: "Compare two models in a table."))
            app.playground.messages.append(PlaygroundMessage(role: .assistant, content: markdownSample, model: app.playground.modelName))
        case "settings":
            // The Settings window doesn't open in the background: show its content here.
            app.debugSettingsTab = SettingsView.Tab(rawValue: argument) ?? .servers
            app.debugShowsSettings = argument != "off"
        case "shot":
            await shot(argument)
        case "print":
            printState()
        case "quit":
            NSApp.terminate(nil)
        default:
            log("script: unknown command \(name)")
        }
        // Let SwiftUI apply the change before the next command.
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Captures the window alone, even when other windows cover it.
    private static func shot(_ name: String) async {
        guard let window, let folder = ProcessInfo.processInfo.environment["OLLAMA_GUI_SHOTS"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent("\(name).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // With a sheet open, the window can't be captured: the sheet is.
        let target = window.attachedSheet ?? window
        process.arguments = ["-x", "-o", "-l", String(target.windowNumber), path]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
            process.waitUntilExit()
            let message = (String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").replacingOccurrences(of: "\n", with: " ")
            log("shot \(name): \(process.terminationStatus == 0 ? "ok" : "failed \(message)")")
        } catch {
            log("shot \(name): \(error.localizedDescription)")
        }
    }

    private static func printState() {
        let app = AppModel.shared
        let settings = app.settings
        let size = window.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" } ?? "-"
        if let request = app.deleteRequest {
            log("dialog: \(app.deleteTitle(for: request)) | \(app.deleteMessage(for: request).replacingOccurrences(of: "\n", with: " / "))")
        }
        let discover = app.discover
        log("discover: results=\(discover.results.count) hasMore=\(discover.hasMore) loading=\(discover.isLoading) more=\(discover.isLoadingMore) error=\(discover.error ?? "-") selection=\(discover.selection ?? "-") query=\"\(discover.query)\"")
        log("state: section=\(app.section?.rawValue ?? "-") connection=\(app.connection) models=\(app.models.count) visible=\(app.visibleModels.count) selected=\(app.modelSelection.count) search=\"\(app.modelSearch)\" filter=\(app.modelFilter.rawValue) running=\(app.running.count) downloads=\(app.downloads.tasks.count) delete=\(app.deleteRequest?.names.count ?? 0) appearance=\(settings.appearance) keepAlive=\(settings.keepAliveSeconds) refresh=\(settings.refreshInterval) servers=\(settings.servers.map(\.address)) window=\(size)")
    }

    private static func log(_ text: String) {
        print(text)
        fflush(stdout)
    }

    private static let markdownSample = """
    ## Two small models

    Both run well on a laptop; **gemma3** is faster, *qwen3* reasons better.

    | Model | Size | Speed |
    |:---|:---:|---:|
    | `gemma3:4b` | 3.3 GB | 62 t/s |
    | `qwen3:8b` | 5.2 GB | 41 t/s |

    1. Pull one:
       ```bash
       ollama pull gemma3:4b
       ```
    2. Try it here.
       - nested point

    > Numbers measured on an M5 with the default context.

    ---
    Done.
    """
}

private extension Array where Element == String {
    func splitPair() -> (String, String) {
        (first ?? "", count > 1 ? self[1] : "")
    }
}
#endif
