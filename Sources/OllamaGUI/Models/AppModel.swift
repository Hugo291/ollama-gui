import AppKit
import Foundation
import OllamaKit
import Observation

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case models
    case running
    case downloads
    case discover
    case playground

    var id: String { rawValue }
}

enum ConnectionState: Equatable {
    case connecting
    case connected(version: String)
    case unreachable(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct ErrorAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct CopyRequest: Identifiable {
    enum Mode {
        case duplicate
        case rename
    }

    let id = UUID()
    let source: String
    let mode: Mode
}

struct CreateRequest: Identifiable {
    let id = UUID()
    let base: String
}

struct DeleteRequest: Identifiable {
    let id = UUID()
    let names: [String]
}

@MainActor
@Observable
final class AppModel {
    /// The single app state. Views read it directly rather than through the SwiftUI
    /// environment: table cells and split view columns can be updated after they left
    /// the hierarchy, where an environment object is no longer available.
    #if DEBUG
    static let shared = AppModel(settings: ScriptDriver.settings())
    #else
    static let shared = AppModel()
    #endif

    let settings: AppSettings
    let downloads = DownloadManager()
    let playground = PlaygroundModel()
    let discover = DiscoverModel()

    // Server state
    private(set) var connection: ConnectionState = .connecting
    private(set) var models: [OllamaModel] = []
    private(set) var running: [RunningModel] = []
    private(set) var hasLoadedModels = false
    private(set) var updates: [String: UpdateStatus] = [:]
    private(set) var isCheckingUpdates = false
    private(set) var lastUpdateCheck: Date?
    /// Models being loaded or unloaded.
    private(set) var busyModels: Set<String> = []

    // UI state
    var section: SidebarSection? = .models
    var modelSelection: Set<String> = []
    /// Search and filter of the Models table. Models they hide leave the selection, so
    /// that nothing acts on a model that isn't shown.
    var modelSearch = "" {
        didSet { pruneSelection() }
    }
    var modelFilter: ModelFilter = .all {
        didSet { pruneSelection() }
    }
    var isPullSheetPresented = false
    var pullSheetPrefill = ""
    var copyRequest: CopyRequest?
    var createRequest: CreateRequest?
    var deleteRequest: DeleteRequest?
    var errorAlert: ErrorAlert?

    @ObservationIgnored private var detailsCache: [String: ModelShowResponse] = [:]
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var refreshCount = 0
    @ObservationIgnored private var didRunLaunchUpdateCheck = false

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
        playground.onReplyEnded = { [weak self] in
            Task { await self?.refreshRunning() }
        }
        downloads.onCompleted = { [weak self] task in
            guard let self, task.serverID == self.settings.selectedServerID else { return }
            self.updates[task.modelName] = nil
            if let match = self.models.first(where: { ModelReference.canonical($0.name) == ModelReference.canonical(task.modelName) }) {
                self.updates[match.name] = nil
            }
            Task { await self.refreshModels() }
        }
        startMonitoring()
    }

    var client: OllamaClient { OllamaClient(baseURL: settings.currentServer.url) }

    // MARK: - Monitoring

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.settings.refreshInterval))
            }
        }
    }

    /// Pings the server, then refreshes running models (every time) and the model list (periodically).
    func refresh(forceModels: Bool = false) async {
        let serverID = settings.selectedServerID
        let client = self.client
        do {
            let version = try await client.version()
            guard serverID == settings.selectedServerID else { return }
            let wasConnected = connection.isConnected
            connection = .connected(version: version)
            if forceModels || !wasConnected || !hasLoadedModels || refreshCount % 5 == 0 {
                await refreshModels()
            }
            await refreshRunning()
            if settings.checkUpdatesOnLaunch, !didRunLaunchUpdateCheck, hasLoadedModels {
                didRunLaunchUpdateCheck = true
                Task { await checkForUpdates() }
            }
        } catch {
            guard serverID == settings.selectedServerID, !(error is CancellationError) else { return }
            connection = .unreachable(error.localizedDescription)
            running = []
        }
        refreshCount += 1
    }

    func refreshModels() async {
        let serverID = settings.selectedServerID
        do {
            let list = try await client.models()
            guard serverID == settings.selectedServerID else { return }
            models = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            hasLoadedModels = true
            let names = Set(models.map(\.name))
            pruneSelection()
            updates = updates.filter { names.contains($0.key) }
        } catch {
            // The next refresh reports connection problems.
        }
    }

    func refreshRunning() async {
        let serverID = settings.selectedServerID
        guard let list = try? await client.runningModels(), serverID == settings.selectedServerID else { return }
        running = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func selectServer(_ id: UUID) {
        guard id != settings.selectedServerID else { return }
        settings.selectedServerID = id
        serverDidChange()
    }

    /// Resets everything bound to the previous server and reconnects.
    func serverDidChange() {
        connection = .connecting
        models = []
        running = []
        updates = [:]
        hasLoadedModels = false
        modelSelection = []
        detailsCache = [:]
        didRunLaunchUpdateCheck = false
        Task { await refresh(forceModels: true) }
    }

    // MARK: - Queries

    /// Models the Models table shows: the filter and the search applied, not sorted.
    var visibleModels: [OllamaModel] {
        let query = modelSearch.trimmingCharacters(in: .whitespaces)
        return models
            .filter { modelFilter.matches($0) }
            .filter { model in
                query.isEmpty
                    || model.name.localizedCaseInsensitiveContains(query)
                    || (model.family?.localizedCaseInsensitiveContains(query) ?? false)
            }
    }

    private func pruneSelection() {
        let visible = Set(visibleModels.map(\.name))
        let pruned = modelSelection.intersection(visible)
        if pruned != modelSelection { modelSelection = pruned }
    }

    /// The model selected in the Models table, when exactly one is selected.
    var selectedModel: OllamaModel? {
        guard modelSelection.count == 1, let name = modelSelection.first else { return nil }
        return model(named: name)
    }

    func model(named name: String) -> OllamaModel? {
        models.first { $0.name == name }
    }

    func runningModel(named name: String) -> RunningModel? {
        running.first { $0.name == name || $0.model == name }
    }

    func isRunning(_ name: String) -> Bool {
        runningModel(named: name) != nil
    }

    func isInstalled(_ name: String) -> Bool {
        let canonical = ModelReference.canonical(name)
        return models.contains { ModelReference.canonical($0.name) == canonical }
    }

    /// Installed models whose name starts with a library model name (`qwen3` → `qwen3:8b`, `qwen3:latest`).
    func installedTags(of libraryModel: LibraryModel) -> [OllamaModel] {
        let prefix = libraryModel.pullName.lowercased() + ":"
        return models.filter { $0.name.lowercased().hasPrefix(prefix) }
    }

    var diskUsage: Int64 {
        models.filter { !$0.isCloud }.reduce(0) { $0 + $1.size }
    }

    var memoryUsage: Int64 {
        running.reduce(0) { $0 + $1.size }
    }

    var availableUpdates: [String] {
        updates.filter { $0.value == .available }.map(\.key).sorted()
    }

    func activeDownload(for name: String) -> DownloadTask? {
        downloads.activeTask(for: name, serverID: settings.selectedServerID)
    }

    func details(for model: OllamaModel) async throws -> ModelShowResponse {
        let key = "\(model.name)@\(model.digest)"
        if let cached = detailsCache[key] { return cached }
        let info = try await client.show(model.name)
        detailsCache[key] = info
        return info
    }

    // MARK: - Actions

    func presentPullSheet(prefill: String = "") {
        pullSheetPrefill = prefill
        isPullSheetPresented = true
    }

    func pull(_ name: String) {
        downloads.pull(name, server: settings.currentServer)
    }

    func requestDelete(_ names: [String]) {
        guard !names.isEmpty else { return }
        deleteRequest = DeleteRequest(names: names.sorted())
    }

    /// Deletes models one after the other on the server they were chosen on, unloading them first.
    func delete(_ names: [String]) async {
        let serverID = settings.selectedServerID
        let client = self.client
        var failures: [(name: String, message: String)] = []
        for name in names {
            guard serverID == settings.selectedServerID else { return }
            do {
                if isRunning(name) { try? await client.unload(name) }
                try await client.delete(name)
                modelSelection.remove(name)
                updates[name] = nil
            } catch {
                failures.append((name, error.localizedDescription))
            }
        }
        if failures.count == 1, let failure = failures.first {
            errorAlert = ErrorAlert(title: String(localized: "Couldn't delete \(failure.name)"), message: failure.message)
        } else if let failure = failures.first {
            errorAlert = ErrorAlert(
                title: String(localized: "Couldn't delete \(failures.count) models"),
                message: Self.nameList(failures.map(\.name)) + "\n\n" + failure.message
            )
        }
        await refreshModels()
        await refreshRunning()
    }

    func copy(from source: String, to destination: String) async throws {
        try await client.copy(from: source, to: destination)
        await refreshModels()
    }

    /// Ollama has no rename: copy, then delete the original, on the same server.
    func rename(from source: String, to destination: String) async throws {
        let serverID = settings.selectedServerID
        let client = self.client
        try await client.copy(from: source, to: destination)
        if isRunning(source) { try? await client.unload(source) }
        try await client.delete(source)
        guard serverID == settings.selectedServerID else { return }
        await refreshModels()
        modelSelection = [destination]
    }

    // MARK: Several models

    /// Models a pull can update: installed from a registry, not cloud models.
    func updatableNames(_ names: [String]) -> [String] {
        names.filter { name in model(named: name).map { !$0.isCloud && $0.reference != nil } ?? false }
    }

    func updateModels(_ names: [String]) {
        updatableNames(names).forEach(pull)
    }

    func unloadModels(_ names: [String]) async {
        for name in names where isRunning(name) {
            await unload(name)
        }
    }

    func deleteTitle(for request: DeleteRequest) -> String {
        if request.names.count == 1, let name = request.names.first {
            return String(localized: "Delete “\(name)”?")
        }
        return String(localized: "Delete \(request.names.count) models?")
    }

    /// The models (when there are several), then the disk space the deletion frees.
    func deleteMessage(for request: DeleteRequest) -> String {
        let size = request.names.compactMap(model(named:)).filter { !$0.isCloud }.reduce(0) { $0 + $1.size }
        let consequence = size > 0
            ? String(localized: "This frees \(Format.bytes(size)) of disk space. Deleted models can be pulled again at any time.")
            : String(localized: "Deleted models can be pulled again at any time.")
        return request.names.count > 1 ? Self.nameList(request.names) + "\n\n" + consequence : consequence
    }

    /// `a, b, c, d, e and 3 others`.
    static func nameList(_ names: [String]) -> String {
        let shown = names.prefix(5).joined(separator: ", ")
        let others = names.count - 5
        return others > 0 ? String(localized: "\(shown) and \(others) others") : shown
    }

    func load(_ name: String, keepAlive: Int? = nil) async {
        guard let model = model(named: name), model.canLoad else { return }
        busyModels.insert(name)
        defer { busyModels.remove(name) }
        do {
            try await client.load(name, keepAlive: keepAlive ?? settings.keepAliveSeconds, isEmbedding: model.supports(.embedding))
        } catch {
            present(error, title: String(localized: "Couldn't load \(name)"))
        }
        await refreshRunning()
    }

    func unload(_ name: String) async {
        busyModels.insert(name)
        defer { busyModels.remove(name) }
        do {
            try await client.unload(name)
        } catch {
            present(error, title: String(localized: "Couldn't unload \(name)"))
        }
        await refreshRunning()
    }

    func unloadAll() async {
        for model in running {
            await unload(model.name)
        }
    }

    func checkForUpdates() async {
        guard !isCheckingUpdates else { return }
        let candidates = models.filter { !$0.isCloud && ($0.reference?.isOfficialRegistry ?? false) }
        guard !candidates.isEmpty else { return }
        isCheckingUpdates = true
        defer {
            isCheckingUpdates = false
            lastUpdateCheck = Date()
        }
        let serverID = settings.selectedServerID
        for model in candidates { updates[model.name] = .checking }

        let registry = RegistryClient()
        await withTaskGroup(of: (OllamaModel, UpdateStatus).self) { group in
            var next = 0
            func enqueue() {
                guard next < candidates.count else { return }
                let model = candidates[next]
                next += 1
                group.addTask { (model, await registry.status(for: model)) }
            }
            for _ in 0..<4 { enqueue() }
            while let (checked, status) = await group.next() {
                // Another server, or a model that changed meanwhile (pulled, deleted): the result is stale.
                if serverID == settings.selectedServerID {
                    if model(named: checked.name)?.digest == checked.digest {
                        updates[checked.name] = status
                    } else if updates[checked.name] == .checking {
                        updates[checked.name] = nil
                    }
                }
                enqueue()
            }
        }
    }

    func updateAll() {
        for name in availableUpdates { pull(name) }
    }

    func openPlayground(with name: String) {
        playground.modelName = name
        section = .playground
    }

    /// Shows a model in the Models table, clearing a search or filter that hides it.
    func reveal(_ name: String) {
        section = .models
        if !visibleModels.contains(where: { $0.name == name }) {
            modelSearch = ""
            modelFilter = .all
        }
        modelSelection = [name]
    }

    func present(_ error: Error, title: String) {
        errorAlert = ErrorAlert(title: title, message: error.localizedDescription)
    }

    // MARK: - Local Ollama

    var canStartLocalOllama: Bool {
        settings.currentServer.isLocal && OllamaLauncher.isInstalled
    }

    func startLocalOllama() {
        OllamaLauncher.launch()
        connection = .connecting
        Task {
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(1))
                await refresh(forceModels: true)
                if connection.isConnected { return }
            }
        }
    }
}

/// Starts the local Ollama server: the menu bar app when installed, otherwise `ollama serve`.
enum OllamaLauncher {
    private static let bundleIdentifiers = ["com.electron.ollama", "com.ollama.ollama"]
    private static let binaryPaths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]

    static var appURL: URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return url }
        }
        let fallback = URL(fileURLWithPath: "/Applications/Ollama.app")
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static var binaryURL: URL? {
        binaryPaths.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { appURL != nil || binaryURL != nil }

    static func launch() {
        if let appURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } else if let binaryURL {
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}
