import OllamaKit
import SwiftUI

struct RunningView: View {
    private var app: AppModel { .shared }

    var body: some View {
        content
            .navigationTitle(Text("Running"))
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItemGroup {
                    LoadModelMenu()
                    Button {
                        Task { await app.unloadAll() }
                    } label: {
                        Label("Unload All", systemImage: "eject")
                    }
                    .help(Text("Unload every model from memory"))
                    .disabled(app.running.isEmpty)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !app.connection.isConnected {
            ServerUnavailableView()
        } else if app.running.isEmpty {
            ContentUnavailableView {
                Label("No Models in Memory", systemImage: "memorychip")
            } description: {
                Text("Models load automatically when they are used, and unload when their keep-alive expires.")
            } actions: {
                LoadModelMenu()
                    .fixedSize()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if app.settings.currentServer.isLocal {
                        MemoryGauge(used: app.memoryUsage)
                    }
                    ForEach(app.running) { model in
                        RunningModelCard(model: model)
                    }
                }
                .padding(20)
            }
        }
    }

    private var subtitle: String {
        guard !app.running.isEmpty else { return "" }
        return String(localized: "\(app.running.count) loaded") + " · " + Format.bytes(app.memoryUsage)
    }
}

private struct MemoryGauge: View {
    let used: Int64
    private let total = Int64(ProcessInfo.processInfo.physicalMemory)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Memory used by models")
                    .font(.headline)
                Spacer()
                Text("\(Format.bytes(used)) of \(Format.bytes(total))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: Double(used), total: Double(max(total, 1)))
                .tint(Double(used) / Double(max(total, 1)) > 0.8 ? .orange : .accentColor)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RunningModelCard: View {
    private var app: AppModel { .shared }
    let model: RunningModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ModelIcon(kind: installed.map(ModelKind.init) ?? .text, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: model.name)
                        .font(.headline)
                    Text(verbatim: detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if app.busyModels.contains(model.name) {
                    ProgressView()
                        .controlSize(.small)
                }
                Menu {
                    ForEach(KeepAliveOption.choices, id: \.self) { seconds in
                        Button(KeepAliveOption.title(for: seconds)) {
                            Task { await app.load(model.name, keepAlive: seconds) }
                        }
                    }
                } label: {
                    Label("Keep Loaded", systemImage: "clock.arrow.circlepath")
                }
                .fixedSize()
                .help(Text("Keep the model in memory for longer"))
                .disabled(installed?.canLoad != true)

                if installed?.canChat == true {
                    Button {
                        app.openPlayground(with: model.name)
                    } label: {
                        Label("Chat", systemImage: "text.bubble")
                    }
                }
                Button {
                    Task { await app.unload(model.name) }
                } label: {
                    Label("Unload", systemImage: "eject")
                }
                .disabled(app.busyModels.contains(model.name))
            }

            HStack(alignment: .top, spacing: 28) {
                Metric(title: Text("Memory"), value: Text(verbatim: Format.bytes(model.size)))
                Metric(title: Text("Processor"), value: Text(verbatim: model.processorLabel))
                if let context = model.contextLength {
                    Metric(title: Text("Context"), value: Text("\(Format.tokens(context)) tokens"))
                }
                Metric(title: Text("Unloads"), value: expiry)
            }

            ProgressView(value: model.gpuShare)
                .tint(.green)
                .help(Text(verbatim: model.processorLabel))
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.separator))
    }

    private var installed: OllamaModel? { app.model(named: model.name) }

    private var detailLine: String {
        [model.details?.family, model.details?.parameterSize, model.details?.quantizationLevel]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }

    private var expiry: Text {
        guard let expiresAt = model.expiresAt else { return Text(verbatim: "—") }
        if model.staysLoaded { return Text("Never") }
        if expiresAt <= .now { return Text("Now") }
        return Text(expiresAt, style: .relative)
    }
}

/// Menu listing the installed models that can be loaded into memory.
struct LoadModelMenu: View {
    private var app: AppModel { .shared }

    var body: some View {
        let candidates = app.models.filter { $0.canLoad && !app.isRunning($0.name) }
        Menu {
            ForEach(candidates) { model in
                Button(model.name) {
                    Task { await app.load(model.name) }
                }
            }
        } label: {
            Label("Load Model", systemImage: "memorychip")
        }
        .help(Text("Load a model into memory for \(KeepAliveOption.title(for: app.settings.keepAliveSeconds))"))
        .accessibilityLabel(Text("Load Model"))
        .disabled(candidates.isEmpty || !app.connection.isConnected)
    }
}
