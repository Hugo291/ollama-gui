import AppKit
import Foundation
import OllamaKit
import Observation
import SwiftUI

/// An Ollama server the app can connect to.
struct ServerConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var address: String

    init(id: UUID = UUID(), name: String, address: String) {
        self.id = id
        self.name = name
        self.address = address
    }

    static let fallbackURL = URL(string: "http://127.0.0.1:11434")!

    var url: URL { OllamaClient.baseURL(from: address) ?? Self.fallbackURL }

    var isValid: Bool { OllamaClient.baseURL(from: address) != nil }

    /// Whether the server runs on this Mac (enables "Start Ollama" and memory gauges).
    var isLocal: Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }

    static func defaultLocal() -> ServerConfig {
        let environment = ProcessInfo.processInfo.environment["OLLAMA_HOST"].flatMap { OllamaClient.baseURL(from: $0) }
        return ServerConfig(name: String(localized: "This Mac"), address: environment?.absoluteString ?? "http://127.0.0.1:11434")
    }
}

/// How long models stay in memory after being loaded or used from the app.
/// There is deliberately no "forever" option.
enum KeepAliveOption {
    static let choices: [Int] = [60, 300, 900, 1800, 3600]
    static let defaultValue = 300

    static func title(for seconds: Int) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}

enum RefreshOption {
    static let choices: [Double] = [2, 3, 5, 10, 30]
    static let defaultValue: Double = 3
}

/// The closest allowed value: settings written by hand or by another version stay usable.
func nearestChoice<Value: BinaryFloatingPoint>(_ value: Value, in choices: [Value]) -> Value {
    choices.min { abs($0 - value) < abs($1 - value) } ?? value
}

func nearestChoice(_ value: Int, in choices: [Int]) -> Int {
    choices.min { abs($0 - value) < abs($1 - value) } ?? value
}

enum Appearance: Int, CaseIterable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: LocalizedStringKey("System")
        case .light: LocalizedStringKey("Light")
        case .dark: LocalizedStringKey("Dark")
        }
    }

    /// Windows, sheets and menus follow it.
    @MainActor func apply() {
        NSApp?.appearance = switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    private enum Keys {
        static let servers = "servers"
        static let selectedServer = "selectedServerID"
        static let keepAlive = "keepAliveSeconds"
        static let refreshInterval = "refreshInterval"
        static let showMenuBarExtra = "showMenuBarExtra"
        static let checkUpdatesOnLaunch = "checkUpdatesOnLaunch"
        static let appearance = "appearance"
        static let modelsTableColumns = "modelsTableColumns"
        static let importedVersion2 = "importedVersion2Settings"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var servers: [ServerConfig] {
        didSet {
            if servers.isEmpty { servers = [.defaultLocal()] }
            if !servers.contains(where: { $0.id == selectedServerID }) { selectedServerID = servers[0].id }
            if let data = try? JSONEncoder().encode(servers) { defaults.set(data, forKey: Keys.servers) }
        }
    }

    var selectedServerID: UUID {
        didSet { defaults.set(selectedServerID.uuidString, forKey: Keys.selectedServer) }
    }

    /// Seconds a model stays in memory after it is loaded or used from the app.
    var keepAliveSeconds: Int {
        didSet { defaults.set(keepAliveSeconds, forKey: Keys.keepAlive) }
    }

    /// Seconds between two refreshes of the server state.
    var refreshInterval: Double {
        didSet { defaults.set(refreshInterval, forKey: Keys.refreshInterval) }
    }

    var showMenuBarExtra: Bool {
        didSet { defaults.set(showMenuBarExtra, forKey: Keys.showMenuBarExtra) }
    }

    var checkUpdatesOnLaunch: Bool {
        didSet { defaults.set(checkUpdatesOnLaunch, forKey: Keys.checkUpdatesOnLaunch) }
    }

    var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
            appearance.apply()
        }
    }

    init(defaults: UserDefaults = .standard, version2Settings: URL? = AppSettings.version2SettingsURL) {
        self.defaults = defaults
        if let version2Settings {
            Self.importVersion2Settings(from: version2Settings, into: defaults)
        }

        var servers: [ServerConfig] = []
        if let data = defaults.data(forKey: Keys.servers), let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = decoded
        }
        if servers.isEmpty { servers = [.defaultLocal()] }
        self.servers = servers

        let storedID = defaults.string(forKey: Keys.selectedServer).flatMap(UUID.init(uuidString:))
        selectedServerID = servers.first { $0.id == storedID }?.id ?? servers[0].id

        let keepAlive = defaults.integer(forKey: Keys.keepAlive)
        keepAliveSeconds = keepAlive > 0 ? nearestChoice(keepAlive, in: KeepAliveOption.choices) : KeepAliveOption.defaultValue

        let interval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = interval > 0 ? nearestChoice(interval, in: RefreshOption.choices) : RefreshOption.defaultValue

        showMenuBarExtra = defaults.object(forKey: Keys.showMenuBarExtra) as? Bool ?? true
        checkUpdatesOnLaunch = defaults.object(forKey: Keys.checkUpdatesOnLaunch) as? Bool ?? false
        appearance = Appearance(rawValue: defaults.integer(forKey: Keys.appearance)) ?? .system
    }

    /// Columns of the Models table (order, widths, hidden ones), as SwiftUI encodes them.
    var modelsTableColumns: Data? {
        get { defaults.data(forKey: Keys.modelsTableColumns) }
        set { defaults.set(newValue, forKey: Keys.modelsTableColumns) }
    }

    // MARK: Version 2

    /// Where version 2 (Rust and Slint, 2026) kept its settings.
    nonisolated static var version2SettingsURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "com.hfc.Ollama-GUI/settings.json")
    }

    /// Copies the servers and choices of version 2 once, so that going back to this app
    /// keeps them. Version 2 replaced version 1, so its settings are the most recent ones:
    /// they replace what version 1 stored. Unknown or invalid values are skipped.
    static func importVersion2Settings(from url: URL, into defaults: UserDefaults) {
        guard !defaults.bool(forKey: Keys.importedVersion2) else { return }
        defaults.set(true, forKey: Keys.importedVersion2)
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        if let list = json["servers"] as? [[String: Any]] {
            var servers: [ServerConfig] = []
            var selected: UUID?
            for entry in list {
                guard let address = entry["address"] as? String, OllamaClient.baseURL(from: address) != nil else { continue }
                let name = (entry["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let server = ServerConfig(name: name.isEmpty ? String(localized: "This Mac") : name, address: address)
                servers.append(server)
                if let id = entry["id"] as? String, id == json["selected_server"] as? String {
                    selected = server.id
                }
            }
            if !servers.isEmpty, let encoded = try? JSONEncoder().encode(servers) {
                defaults.set(encoded, forKey: Keys.servers)
                defaults.set((selected ?? servers[0].id).uuidString, forKey: Keys.selectedServer)
            }
        }
        if let seconds = (json["keep_alive_seconds"] as? NSNumber)?.intValue, seconds > 0 {
            defaults.set(nearestChoice(seconds, in: KeepAliveOption.choices), forKey: Keys.keepAlive)
        }
        if let seconds = (json["refresh_seconds"] as? NSNumber)?.doubleValue, seconds > 0 {
            defaults.set(nearestChoice(seconds, in: RefreshOption.choices), forKey: Keys.refreshInterval)
        }
        if let check = json["check_updates_on_launch"] as? Bool {
            defaults.set(check, forKey: Keys.checkUpdatesOnLaunch)
        }
        if let show = json["show_tray_icon"] as? Bool {
            defaults.set(show, forKey: Keys.showMenuBarExtra)
        }
        if let theme = (json["theme"] as? NSNumber)?.intValue, let appearance = Appearance(rawValue: theme) {
            defaults.set(appearance.rawValue, forKey: Keys.appearance)
        }
    }

    var currentServer: ServerConfig {
        servers.first { $0.id == selectedServerID } ?? servers[0]
    }
}
