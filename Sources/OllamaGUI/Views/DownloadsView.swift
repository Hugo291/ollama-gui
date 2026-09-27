import OllamaKit
import SwiftUI

struct DownloadsView: View {
    private var app: AppModel { .shared }

    var body: some View {
        content
            .navigationTitle(Text("Downloads"))
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        app.downloads.clearFinished()
                    } label: {
                        Label("Clear Finished", systemImage: "xmark.circle")
                    }
                    .help(Text("Remove finished downloads from the list"))
                    .disabled(app.downloads.tasks.allSatisfy(\.isActive))

                    Button {
                        app.presentPullSheet()
                    } label: {
                        Label("Pull Model", systemImage: "plus")
                    }
                    .help(Text("Download a model from the Ollama library"))
                    .disabled(!app.connection.isConnected)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if app.downloads.tasks.isEmpty {
            ContentUnavailableView {
                Label("No Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text("Models you pull or update appear here with their progress.")
            } actions: {
                Button("Pull a Model…") { app.presentPullSheet() }
                    .buttonStyle(.borderedProminent)
                Button("Discover Models") { app.section = .discover }
            }
        } else {
            List {
                ForEach(app.downloads.tasks) { download in
                    DownloadRow(download: download)
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct DownloadRow: View {
    private var app: AppModel { .shared }
    let download: DownloadTask

    var body: some View {
        HStack(spacing: 12) {
            stateIcon
                .font(.title2)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: download.modelName)
                        .font(.headline)
                    if app.settings.servers.count > 1 {
                        Text(verbatim: download.serverName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if download.isActive, let fraction = download.fractionCompleted {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if download.isActive {
                    if let fraction = download.fractionCompleted {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                detail
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }

            actions
        }
        .padding(.vertical, 6)
    }

    private var isFailure: Bool {
        if case .failed = download.state { return true }
        return false
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch download.state {
        case .running:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var detail: Text {
        switch download.state {
        case .running:
            var parts: [String] = [Format.progressStatus(download.status.isEmpty ? "pulling manifest" : download.status)]
            if download.totalBytes > 0 {
                parts.append(String(localized: "\(Format.bytes(download.completedBytes)) of \(Format.bytes(download.totalBytes))"))
            }
            if download.bytesPerSecond > 0 {
                parts.append(Format.bytes(Int64(download.bytesPerSecond)) + "/s")
            }
            if let remaining = download.remainingTime {
                let duration = Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
                parts.append(String(localized: "\(duration) remaining"))
            }
            return Text(verbatim: parts.joined(separator: " · "))
        case .completed:
            let elapsed = (download.finishedAt ?? .now).timeIntervalSince(download.startedAt)
            let duration = Duration.seconds(max(1, elapsed)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
            if download.totalBytes > 0 {
                return Text("Completed in \(duration) · \(Format.bytes(download.totalBytes))")
            }
            return Text("Completed in \(duration)")
        case .failed(let message):
            return Text(verbatim: message)
        case .cancelled:
            return Text("Cancelled")
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            switch download.state {
            case .running:
                Button {
                    app.downloads.cancel(download)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .help(Text("Cancel"))
            case .completed:
                if download.serverID == app.settings.selectedServerID, app.isInstalled(download.modelName) {
                    Button {
                        if let model = app.models.first(where: { ModelReference.canonical($0.name) == ModelReference.canonical(download.modelName) }) {
                            app.reveal(model.name)
                        }
                    } label: {
                        Image(systemName: "magnifyingglass.circle")
                    }
                    .help(Text("Show in Models"))
                }
                removeButton
            case .failed, .cancelled:
                Button {
                    app.downloads.retry(download)
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
                .help(Text("Retry"))
                removeButton
            }
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    private var removeButton: some View {
        Button {
            app.downloads.remove(download)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .help(Text("Remove from List"))
    }
}
