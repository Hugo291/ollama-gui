import OllamaKit
import SwiftUI

/// Inspector column of the Models section.
struct ModelInspector: View {
    private var app: AppModel { .shared }

    var body: some View {
        let selection = app.modelSelection
        if selection.count == 1, let name = selection.first, let model = app.model(named: name) {
            ModelDetailView(model: model)
                .id(model.id)
        } else if selection.count > 1 {
            MultipleSelectionView(names: selection.sorted())
        } else {
            ContentUnavailableView {
                Label("No Selection", systemImage: "cursorarrow.rays")
            } description: {
                Text("Select a model to see its details.")
            }
        }
    }
}

/// Several models selected: how many, their size, and what can be done to all of them.
private struct MultipleSelectionView: View {
    private var app: AppModel { .shared }
    let names: [String]

    var body: some View {
        let models = names.compactMap(app.model(named:))
        let size = models.filter { !$0.isCloud }.reduce(0) { $0 + $1.size }
        let running = names.filter(app.isRunning).count
        let updatable = app.updatableNames(names)
        ContentUnavailableView {
            Label("\(names.count) models selected", systemImage: "square.stack.3d.up")
        } description: {
            if running > 0 {
                Text(verbatim: Format.bytes(size) + " · " + String(localized: "\(running) loaded"))
            } else {
                Text(verbatim: Format.bytes(size))
            }
        } actions: {
            VStack(spacing: 8) {
                Button("Update \(updatable.count) Models") { app.updateModels(names) }
                    .disabled(updatable.isEmpty || !app.connection.isConnected)
                if running > 0 {
                    Button("Unload from Memory") { Task { await app.unloadModels(names) } }
                }
                Button("Delete \(names.count) Models…", role: .destructive) { app.requestDelete(names) }
            }
        }
    }
}

struct ModelDetailView: View {
    private var app: AppModel { .shared }
    let model: OllamaModel

    @State private var info: ModelShowResponse?
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                Divider()
                facts
                if let info {
                    DetailSections(info: info)
                } else if let loadError {
                    Label {
                        Text(verbatim: loadError)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .task(id: model.digest) {
            do {
                info = try await app.details(for: model)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ModelIcon(kind: ModelKind(model), size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: model.name)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Text(verbatim: summaryLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            FlowLayout(spacing: 4) {
                if model.isCloud {
                    Badge(Text("Cloud"), tint: .teal)
                }
                if app.isRunning(model.name) {
                    Badge(Text("In Memory"), tint: .green)
                }
                if app.updates[model.name] == .available {
                    Badge(Text("Update Available"), tint: .blue)
                } else if app.updates[model.name] == .upToDate {
                    Badge(Text("Up to Date"), tint: .secondary)
                }
                ForEach(model.capabilities ?? [], id: \.self) { capability in
                    Badge(CapabilityStyle.title(capability), tint: CapabilityStyle.tint(capability))
                }
            }
        }
    }

    private var summaryLine: String {
        [model.family, model.parameterSize, model.quantization].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                app.openPlayground(with: model.name)
            } label: {
                Label("Chat", systemImage: "text.bubble")
            }
            .disabled(!model.canChat)

            if app.isRunning(model.name) {
                Button {
                    Task { await app.unload(model.name) }
                } label: {
                    Label("Unload", systemImage: "eject")
                }
                .disabled(app.busyModels.contains(model.name))
            } else if model.canLoad {
                Button {
                    Task { await app.load(model.name) }
                } label: {
                    Label("Load", systemImage: "memorychip")
                }
                .disabled(app.busyModels.contains(model.name))
                .help(Text("Load the model into memory for \(KeepAliveOption.title(for: app.settings.keepAliveSeconds))"))
            }

            if let download = app.activeDownload(for: model.name) {
                ProgressView(value: download.fractionCompleted ?? 0)
                    .frame(width: 60)
            } else if app.updates[model.name] == .available {
                Button {
                    app.pull(model.name)
                } label: {
                    Label("Update", systemImage: "arrow.down.circle")
                }
            }

            if app.busyModels.contains(model.name) {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer(minLength: 0)

            Menu {
                ModelContextMenu(names: [model.name])
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .labelStyle(.titleAndIcon)
    }

    // MARK: Facts

    private var facts: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
            if model.isCloud {
                fact(Text("Runs on"), value: model.remoteHost ?? "ollama.com")
            } else {
                fact(Text("Size"), value: Format.bytes(model.size))
            }
            if let parameters = model.parameterSize ?? info?.parameterCount.map(Format.parameterCount) {
                fact(Text("Parameters"), value: parameters)
            }
            if let quantization = model.quantization {
                fact(Text("Quantization"), value: quantization)
            }
            if let format = model.format {
                fact(Text("Format"), value: format)
            }
            if let architecture = info?.architecture {
                fact(Text("Architecture"), value: architecture)
            }
            if let context = info?.contextLength ?? model.details?.contextLength {
                fact(Text("Context"), value: String(localized: "\(Format.tokens(context)) tokens"))
            }
            if let embedding = info?.embeddingLength {
                fact(Text("Embedding size"), value: String(embedding))
            }
            if let modified = model.modifiedAt, modified.timeIntervalSince1970 > 0 {
                fact(Text("Modified"), value: modified.formatted(date: .abbreviated, time: .shortened))
            }
            if let requires = info?.requires {
                fact(Text("Requires"), value: "Ollama \(requires)")
            }
            if let license = info?.licenseTitle {
                fact(Text("License"), value: license)
            }
            if !model.digest.isEmpty {
                GridRow {
                    Text("Digest")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(verbatim: model.shortDigest)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(text: model.digest)
                    }
                }
            }
        }
        .font(.callout)
    }

    private func fact(_ title: Text, value: String) -> some View {
        GridRow {
            title
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .textSelection(.enabled)
                .lineLimit(3)
        }
    }
}

/// Collapsible sections with the raw model configuration.
private struct DetailSections: View {
    let info: ModelShowResponse
    @State private var expanded: Set<String> = ["parameters", "system"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let parameters = info.parameterList
            if !parameters.isEmpty {
                section("parameters", title: Text("Parameters")) {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(parameters) { parameter in
                            GridRow {
                                Text(verbatim: parameter.key)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: parameter.value)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            if let system = info.system.nonBlank {
                section("system", title: Text("System Prompt")) { CodeBlock(text: system) }
            }
            if let template = info.template.nonBlank {
                section("template", title: Text("Template")) { CodeBlock(text: template) }
            }
            if let modelfile = info.modelfile.nonBlank {
                section("modelfile", title: Text("Modelfile")) { CodeBlock(text: modelfile, maxHeight: 320) }
            }
            if let license = info.license.nonBlank {
                section("license", title: Text("License")) { CodeBlock(text: license, maxHeight: 320) }
            }
            if let modelInfo = info.modelInfo, !modelInfo.isEmpty {
                section("info", title: Text("Model Info")) {
                    CodeBlock(text: modelInfo.keys.sorted().map { "\($0) = \(modelInfo[$0]!.displayString)" }.joined(separator: "\n"), maxHeight: 320)
                }
            }
            if let tensors = info.tensors, !tensors.isEmpty {
                section("tensors", title: Text("Tensors (\(tensors.count))")) {
                    CodeBlock(text: tensors.map { tensor in
                        let shape = tensor.shape.map { "[" + $0.map(String.init).joined(separator: ", ") + "]" } ?? ""
                        return "\(tensor.name)  \(tensor.type ?? "")  \(shape)"
                    }.joined(separator: "\n"), maxHeight: 320)
                }
            }
        }
    }

    private func section(_ id: String, title: Text, @ViewBuilder content: () -> some View) -> some View {
        let content = content()
        return DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(id) } else { expanded.remove(id) }
            }
        )) {
            content
                .padding(.top, 6)
        } label: {
            title.font(.headline)
        }
    }
}

private extension Optional where Wrapped == String {
    var nonBlank: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return self
    }
}
