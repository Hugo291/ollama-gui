import Foundation
import OllamaKit
import Observation

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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var servers: [ServerConfig] = []
        if let data = defaults.data(forKey: Keys.servers), let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = decoded
        }
        if servers.isEmpty { servers = [.defaultLocal()] }
        self.servers = servers

        let storedID = defaults.string(forKey: Keys.selectedServer).flatMap(UUID.init(uuidString:))
        selectedServerID = servers.first { $0.id == storedID }?.id ?? servers[0].id

        let keepAlive = defaults.integer(forKey: Keys.keepAlive)
        keepAliveSeconds = keepAlive > 0 ? keepAlive : KeepAliveOption.defaultValue

        let interval = defaults.double(forKey: Keys.refreshInterval)
        refreshInterval = interval > 0 ? interval : 3

        showMenuBarExtra = defaults.object(forKey: Keys.showMenuBarExtra) as? Bool ?? true
        checkUpdatesOnLaunch = defaults.object(forKey: Keys.checkUpdatesOnLaunch) as? Bool ?? false
    }

    var currentServer: ServerConfig {
        servers.first { $0.id == selectedServerID } ?? servers[0]
    }
}
