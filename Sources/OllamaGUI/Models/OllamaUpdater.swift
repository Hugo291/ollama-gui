import AppKit
import CryptoKit
import Darwin
import Foundation
import OllamaKit

enum OllamaUpdateState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case available([OllamaRelease])
    case installing(OllamaRelease)
    case installed(String)
    case failed(String)
}

struct OllamaInstallProgress: Sendable {
    enum Stage: Int, Sendable {
        case downloadingArchive, downloadingChecksums, verifying, extracting, stopping, installing, restarting

        var title: String {
            switch self {
            case .downloadingArchive: String(localized: "Downloading Ollama…")
            case .downloadingChecksums: String(localized: "Downloading verification file…")
            case .verifying: String(localized: "Verifying the download…")
            case .extracting: String(localized: "Extracting Ollama…")
            case .stopping: String(localized: "Stopping Ollama…")
            case .installing: String(localized: "Replacing the Ollama application…")
            case .restarting: String(localized: "Restarting Ollama and checking its version…")
            }
        }
    }

    var stage: Stage = .downloadingArchive
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }
}

// Mutable completion state is accessed only on URLSession's serial delegate queue.
private final class OllamaDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64, Int64) -> Void
    let destination: URL
    let continuation: CheckedContinuation<Void, Error>
    private var result: Result<Void, Error>?

    init(destination: URL, continuation: CheckedContinuation<Void, Error>,
         report: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.continuation = continuation
        self.report = report
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        result = Result {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else { throw OllamaError.unexpectedResponse }
            // The temporary file is removed after this delegate callback returns.
            try FileManager.default.moveItem(at: location, to: destination)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(with: result ?? .failure(OllamaError.unexpectedResponse))
        }
        session.finishTasksAndInvalidate()
    }
}

enum OllamaUpdateError: LocalizedError {
    case missingApplication
    case missingAssets
    case invalidChecksum
    case invalidArchive
    case permissionDenied
    case applicationStillRunning

    var errorDescription: String? {
        switch self {
        case .missingApplication:
            return String(localized: "The Ollama application could not be found on this Mac.")
        case .missingAssets:
            return String(localized: "This Ollama release does not contain the expected macOS files.")
        case .invalidChecksum:
            return String(localized: "The downloaded Ollama archive failed its SHA-256 verification.")
        case .invalidArchive:
            return String(localized: "The downloaded archive does not contain a valid Ollama application.")
        case .permissionDenied:
            return String(localized: "Ollama GUI does not have permission to replace Ollama in Applications.")
        case .applicationStillRunning:
            return String(localized: "Ollama could not be stopped. The installed application has not been replaced.")
        }
    }
}

struct OllamaUpdater {
    static func install(_ release: OllamaRelease, replacing applicationURL: URL,
                        progress: @escaping @Sendable (OllamaInstallProgress) async -> Void) async throws {
        guard let archive = release.asset(named: "Ollama-darwin.zip"),
              let checksums = release.asset(named: "sha256sum.txt") else {
            throw OllamaUpdateError.missingAssets
        }

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "ollama-gui-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let archiveURL = temporary.appending(path: archive.name)
        let checksumURL = temporary.appending(path: checksums.name)
        try await download(archive, to: archiveURL, stage: .downloadingArchive, progress: progress)
        try await download(checksums, to: checksumURL, stage: .downloadingChecksums, progress: progress)

        await progress(.init(stage: .verifying))
        try await Task.detached { try Self.verify(archive: archiveURL, checksums: checksumURL) }.value
        await progress(.init(stage: .extracting))
        try await Task.detached { try Self.extract(archive: archiveURL, into: temporary) }.value

        let extractedApplication = temporary.appending(path: "Ollama.app", directoryHint: .isDirectory)
        guard let bundle = Bundle(url: extractedApplication),
              bundle.bundleIdentifier == "com.electron.ollama" || bundle.bundleIdentifier == "com.ollama.ollama",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == release.version else {
            throw OllamaUpdateError.invalidArchive
        }

        await progress(.init(stage: .stopping))
        try await stop(applicationURL)

        await progress(.init(stage: .installing))
        do {
            try await Task.detached {
                try Self.replace(applicationURL, with: extractedApplication)
            }.value
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileWriteVolumeReadOnly.rawValue].contains(error.code) {
                throw OllamaUpdateError.permissionDenied
            }
            throw error
        }
    }

    /// A menu bar application can ignore a normal quit request, and its server
    /// can survive it. Only stop processes belonging to the app being replaced.
    static func stop(_ applicationURL: URL) async throws {
        let target = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        let applications = await MainActor.run {
            NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
            }
        }
        await MainActor.run { applications.forEach { $0.terminate() } }
        for _ in 0..<20 {
            if await MainActor.run(body: { applications.allSatisfy(\.isTerminated) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await MainActor.run {
            applications.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        }
        // Stop the server and runners even if the menu bar app left them behind.
        for pid in try processIDs(in: target) { _ = Darwin.kill(pid, SIGTERM) }
        for _ in 0..<50 {
            if try processIDs(in: target).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        for pid in try processIDs(in: target) { _ = Darwin.kill(pid, SIGKILL) }
        for _ in 0..<20 {
            if try processIDs(in: target).isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw OllamaUpdateError.applicationStillRunning
    }

    private static func processIDs(in applicationURL: URL) throws -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-wwaxo", "pid=,comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OllamaUpdateError.applicationStillRunning }
        let prefix = applicationURL.path + "/Contents/"
        return (String(data: data, encoding: .utf8) ?? "").split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = pid_t(fields[0]), pid != getpid(),
                  fields[1].trimmingCharacters(in: .whitespaces).hasPrefix(prefix) else { return nil }
            return pid
        }
    }

    @MainActor
    static func launch(_ applicationURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
    }

    private static func download(_ asset: OllamaRelease.Asset, to localURL: URL,
                                 stage: OllamaInstallProgress.Stage,
                                 progress: @escaping @Sendable (OllamaInstallProgress) async -> Void) async throws {
        let expectedSize = max(0, asset.size ?? 0)
        await progress(.init(stage: stage, totalBytes: expectedSize))
        // Use the delegate-driven task: the async download convenience method
        // consumes the download callbacks instead of forwarding progress here.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = OllamaDownloadProgress(destination: localURL, continuation: continuation) { received, total in
                let expected = total > 0 ? total : expectedSize
                Task { await progress(.init(stage: stage, receivedBytes: received, totalBytes: expected)) }
            }
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: asset.downloadURL).resume()
        }
        let size = (try FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        await progress(.init(stage: stage, receivedBytes: size, totalBytes: size))
    }

    private static func verify(archive: URL, checksums: URL) throws {
        let text = try String(contentsOf: checksums, encoding: .utf8)
        guard let expected = text.split(whereSeparator: \.isNewline)
            .first(where: { $0.hasSuffix("Ollama-darwin.zip") })?
            .split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw OllamaUpdateError.invalidChecksum
        }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw OllamaUpdateError.invalidChecksum
        }
    }

    private static func extract(archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OllamaUpdateError.invalidArchive }
    }

    private static func replace(_ applicationURL: URL, with newApplicationURL: URL) throws {
        let manager = FileManager.default
        let parent = applicationURL.deletingLastPathComponent()
        let staged = parent.appending(path: ".Ollama-update-\(UUID().uuidString).app", directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: staged) }
        try manager.copyItem(at: newApplicationURL, to: staged)
        _ = try manager.replaceItemAt(applicationURL, withItemAt: staged, options: .usingNewMetadataOnly)
    }
}
