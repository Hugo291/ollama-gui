import AppKit
import Foundation
import OllamaKit
import Observation

/// One `ollama pull`, with aggregated progress over all layers.
@MainActor
@Observable
final class DownloadTask: Identifiable {
    enum State: Equatable {
        case running
        case completed
        case failed(String)
        case cancelled
    }

    private struct Layer {
        var total: Int64
        var completed: Int64
    }

    let id = UUID()
    let modelName: String
    let serverID: UUID
    let serverName: String
    @ObservationIgnored let client: OllamaClient

    private(set) var state: State = .running
    private(set) var status = ""
    private(set) var totalBytes: Int64 = 0
    private(set) var completedBytes: Int64 = 0
    private(set) var bytesPerSecond: Double = 0
    private(set) var startedAt = Date()
    private(set) var finishedAt: Date?

    @ObservationIgnored fileprivate var task: Task<Void, Never>?
    @ObservationIgnored private var layers: [String: Layer] = [:]
    @ObservationIgnored private var samples: [(date: Date, bytes: Int64)] = []
    @ObservationIgnored private var lastPublish = Date.distantPast
    @ObservationIgnored fileprivate var sawSuccess = false

    init(modelName: String, serverID: UUID, serverName: String, client: OllamaClient) {
        self.modelName = modelName
        self.serverID = serverID
        self.serverName = serverName
        self.client = client
    }

    var isActive: Bool { state == .running }

    var fractionCompleted: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, Double(completedBytes) / Double(totalBytes))
    }

    var remainingTime: TimeInterval? {
        guard bytesPerSecond > 1, totalBytes > completedBytes else { return nil }
        return Double(totalBytes - completedBytes) / bytesPerSecond
    }

    fileprivate func reset() {
        state = .running
        status = ""
        totalBytes = 0
        completedBytes = 0
        bytesPerSecond = 0
        startedAt = Date()
        finishedAt = nil
        layers = [:]
        samples = []
        lastPublish = .distantPast
        sawSuccess = false
    }

    fileprivate func apply(_ event: ProgressEvent) {
        let now = Date()
        var statusChanged = false
        if let newStatus = event.status, newStatus != status {
            status = newStatus
            statusChanged = true
            if newStatus == "success" { sawSuccess = true }
        }
        if let digest = event.digest, let total = event.total, total > 0 {
            layers[digest] = Layer(total: total, completed: min(event.completed ?? layers[digest]?.completed ?? 0, total))
        }
        // Pull events arrive many times per second: publish at most ~6 times per second.
        guard statusChanged || now.timeIntervalSince(lastPublish) > 0.16 else { return }
        lastPublish = now
        totalBytes = layers.values.reduce(0) { $0 + $1.total }
        completedBytes = layers.values.reduce(0) { $0 + $1.completed }

        samples.append((now, completedBytes))
        samples.removeAll { now.timeIntervalSince($0.date) > 4 }
        if let first = samples.first, now.timeIntervalSince(first.date) > 0.5 {
            bytesPerSecond = max(0, Double(completedBytes - first.bytes) / now.timeIntervalSince(first.date))
        }
    }

    fileprivate func finish(_ state: State) {
        if state == .completed {
            completedBytes = totalBytes
        }
        self.state = state
        bytesPerSecond = 0
        finishedAt = Date()
        task = nil
    }
}

@MainActor
@Observable
final class DownloadManager {
    private(set) var tasks: [DownloadTask] = []

    /// Called when a pull finishes successfully.
    @ObservationIgnored var onCompleted: ((DownloadTask) -> Void)?

    var activeTasks: [DownloadTask] { tasks.filter(\.isActive) }
    var activeCount: Int { tasks.lazy.filter(\.isActive).count }

    @discardableResult
    func pull(_ modelName: String, server: ServerConfig) -> DownloadTask {
        let canonical = ModelReference.canonical(modelName)
        if let existing = tasks.first(where: { $0.isActive && $0.serverID == server.id && ModelReference.canonical($0.modelName) == canonical }) {
            return existing
        }
        let download = DownloadTask(modelName: modelName, serverID: server.id, serverName: server.name, client: OllamaClient(baseURL: server.url))
        tasks.insert(download, at: 0)
        start(download)
        return download
    }

    /// The running pull for a model on a server, if any.
    func activeTask(for modelName: String, serverID: UUID) -> DownloadTask? {
        let canonical = ModelReference.canonical(modelName)
        return tasks.first { $0.isActive && $0.serverID == serverID && ModelReference.canonical($0.modelName) == canonical }
    }

    func cancel(_ download: DownloadTask) {
        download.task?.cancel()
    }

    func retry(_ download: DownloadTask) {
        guard !download.isActive else { return }
        start(download)
    }

    func remove(_ download: DownloadTask) {
        download.task?.cancel()
        tasks.removeAll { $0.id == download.id }
        updateDockBadge()
    }

    func clearFinished() {
        tasks.removeAll { !$0.isActive }
    }

    private func start(_ download: DownloadTask) {
        download.reset()
        updateDockBadge()
        download.task = Task { [weak self, download] in
            let outcome: DownloadTask.State
            do {
                for try await event in download.client.pull(download.modelName) {
                    download.apply(event)
                }
                if Task.isCancelled {
                    outcome = .cancelled
                } else if download.sawSuccess {
                    outcome = .completed
                } else {
                    outcome = .failed(OllamaError.incompleteStream.localizedDescription)
                }
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            download.finish(outcome)
            self?.updateDockBadge()
            if outcome == .completed {
                self?.onCompleted?(download)
            }
        }
    }

    private func updateDockBadge() {
        let count = activeCount
        NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }
}
