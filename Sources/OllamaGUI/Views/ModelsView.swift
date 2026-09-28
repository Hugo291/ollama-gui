import OllamaKit
import SwiftUI

enum ModelFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case cloud
    case vision
    case tools
    case thinking
    case embedding
    case image

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: LocalizedStringKey("All Models")
        case .local: LocalizedStringKey("Local")
        case .cloud: LocalizedStringKey("Cloud")
        case .vision: LocalizedStringKey("Vision")
        case .tools: LocalizedStringKey("Tools")
        case .thinking: LocalizedStringKey("Thinking")
        case .embedding: LocalizedStringKey("Embedding")
        case .image: LocalizedStringKey("Image")
        }
    }

    func matches(_ model: OllamaModel) -> Bool {
        switch self {
        case .all: true
        case .local: !model.isCloud
        case .cloud: model.isCloud
        case .vision: model.supports(.vision)
        case .tools: model.supports(.tools)
        case .thinking: model.supports(.thinking)
        case .embedding: model.supports(.embedding)
        case .image: model.supports(.image)
        }
    }
}

/// Sort keys for the models table (Table columns need non-optional comparable values).
extension OllamaModel {
    var parameterSortValue: Double { Format.parameterValue(parameterSize) }
    var quantizationSortValue: String { quantization ?? "" }
    var modifiedSortValue: Date { modifiedAt ?? .distantPast }
    var sizeSortValue: Int64 { isCloud ? -1 : size }
}

struct ModelsView: View {
    private var app: AppModel { .shared }
    @State private var searchText = ""
    @State private var filter: ModelFilter = .all
    @State private var sortOrder = [KeyPathComparator(\OllamaModel.name, comparator: .localizedStandard)]
    @State private var showInspector = true

    var body: some View {
        content
            .navigationTitle(Text("Models"))
            .navigationSubtitle(subtitle)
            .searchable(text: $searchText, placement: .toolbar, prompt: Text("Filter models"))
            .toolbar { toolbar }
            .inspector(isPresented: $showInspector) {
                ModelInspector()
                    .inspectorColumnWidth(min: 300, ideal: 370, max: 560)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !app.connection.isConnected && app.models.isEmpty {
            ServerUnavailableView()
        } else if !app.hasLoadedModels {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if app.models.isEmpty {
            ContentUnavailableView {
                Label("No Models Yet", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text("Pull a model from the Ollama library to get started.")
            } actions: {
                Button("Pull a Model…") { app.presentPullSheet() }
                    .buttonStyle(.borderedProminent)
                Button("Discover Models") { app.section = .discover }
            }
        } else if rows.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ModelsTable(rows: rows, sortOrder: $sortOrder, showInspector: $showInspector)
        }
    }

    private var rows: [OllamaModel] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return app.models
            .filter { filter.matches($0) }
            .filter { model in
                query.isEmpty
                    || model.name.localizedCaseInsensitiveContains(query)
                    || (model.family?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted(using: sortOrder)
    }

    private var subtitle: String {
        guard app.hasLoadedModels else { return "" }
        var parts = [String(localized: "\(app.models.count) models"), Format.bytes(app.diskUsage)]
        let updates = app.availableUpdates.count
        if updates > 0 {
            parts.append(String(localized: "\(updates) updates available"))
        }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker(selection: $filter) {
                    ForEach(ModelFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                } label: {
                    Text("Filter")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(Text("Show only some kinds of models"))
            .accessibilityLabel(Text("Filter"))

            if !app.availableUpdates.isEmpty {
                Button {
                    app.updateAll()
                } label: {
                    Label("Update All", systemImage: "arrow.down.circle")
                }
                .help(Text("Pull the latest version of every outdated model"))
            }

            Button {
                Task { await app.checkForUpdates() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
            }
            .help(Text("Check the Ollama registry for newer versions of your models"))
            .disabled(!app.connection.isConnected || app.isCheckingUpdates)

            Button {
                app.presentPullSheet()
            } label: {
                Label("Pull Model", systemImage: "plus")
            }
            .help(Text("Download a model from the Ollama library"))
            .disabled(!app.connection.isConnected)

            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(Text("Show or hide model details"))
        }
    }
}

private struct ModelsTable: View {
    private var app: AppModel { .shared }
    let rows: [OllamaModel]
    @Binding var sortOrder: [KeyPathComparator<OllamaModel>]
    @Binding var showInspector: Bool
    /// Widths, order and hidden columns (right-click a column title), kept between launches.
    @State private var columns = Self.savedColumns()

    var body: some View {
        @Bindable var app = app

        Table(rows, selection: $app.modelSelection, sortOrder: $sortOrder, columnCustomization: $columns) {
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { model in
                ModelNameCell(model: model)
            }
            .width(min: 140, ideal: 180)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Parameters", value: \.parameterSortValue) { model in
                Text(verbatim: model.parameterSize ?? "—")
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 70)
            .customizationID("parameters")

            TableColumn("Quantization", value: \.quantizationSortValue) { model in
                Text(verbatim: model.quantization ?? "—")
            }
            .width(min: 64, ideal: 84)
            .customizationID("quantization")

            TableColumn("Size", value: \.sizeSortValue) { model in
                SizeCell(model: model)
            }
            .width(min: 56, ideal: 68)
            .customizationID("size")

            TableColumn("Capabilities") { model in
                CapabilityIcons(capabilities: model.capabilities ?? [])
            }
            .width(min: 64, ideal: 90)
            .customizationID("capabilities")

            TableColumn("Modified", value: \.modifiedSortValue) { model in
                ModifiedCell(date: model.modifiedAt)
            }
            .width(min: 64, ideal: 88)
            .customizationID("modified")
        }
        .onChange(of: columns) { _, columns in
            app.settings.modelsTableColumns = try? JSONEncoder().encode(columns)
        }
        .contextMenu(forSelectionType: String.self) { names in
            ModelContextMenu(names: Array(names))
        } primaryAction: { _ in
            showInspector = true
        }
        .onDeleteCommand {
            app.requestDelete(Array(app.modelSelection))
        }
    }
}

extension ModelsTable {
    private static func savedColumns() -> TableColumnCustomization<OllamaModel> {
        guard let data = AppModel.shared.settings.modelsTableColumns,
              let columns = try? JSONDecoder().decode(TableColumnCustomization<OllamaModel>.self, from: data)
        else { return TableColumnCustomization() }
        return columns
    }
}

private struct ModelNameCell: View {
    private var app: AppModel { .shared }
    let model: OllamaModel

    var body: some View {
        HStack(spacing: 8) {
            ModelIcon(kind: ModelKind(model), size: 20)
            Text(verbatim: model.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if app.isRunning(model.name) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.green)
                    .help(Text("Loaded in memory"))
            }
            if let download = app.activeDownload(for: model.name) {
                ProgressView(value: download.fractionCompleted ?? 0)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .help(Text("Updating…"))
            } else if app.updates[model.name] == .available {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                    .help(Text("Update available"))
            } else if app.updates[model.name] == .checking {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }
}

private struct SizeCell: View {
    let model: OllamaModel

    var body: some View {
        if model.isCloud {
            Text("Cloud")
                .foregroundStyle(.secondary)
        } else {
            Text(verbatim: Format.bytes(model.size))
                .monospacedDigit()
        }
    }
}

private struct ModifiedCell: View {
    let date: Date?

    var body: some View {
        if let date, date.timeIntervalSince1970 > 0 {
            Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                .foregroundStyle(.secondary)
                .help(Text(date, format: .dateTime))
        } else {
            Text(verbatim: "—")
        }
    }
}

/// Actions for one or several models, shared by the table and the inspector.
struct ModelContextMenu: View {
    private var app: AppModel { .shared }
    let names: [String]

    var body: some View {
        if names.count == 1, let name = names.first, let model = app.model(named: name) {
            Button("Chat") { app.openPlayground(with: name) }
                .disabled(!model.canChat)
            if app.isRunning(name) {
                Button("Unload from Memory") { Task { await app.unload(name) } }
            } else {
                Button("Load into Memory") { Task { await app.load(name) } }
                    .disabled(!model.canLoad)
            }
            Divider()
            Button("Update") { app.pull(name) }
                .disabled(app.updatableNames([name]).isEmpty)
            Button("Duplicate…") { app.copyRequest = CopyRequest(source: name, mode: .duplicate) }
            Button("Rename…") { app.copyRequest = CopyRequest(source: name, mode: .rename) }
            Button("Customize…") { app.createRequest = CreateRequest(base: name) }
                .disabled(model.isCloud || !model.canChat)
            Divider()
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(name, forType: .string)
            }
            if let url = model.reference?.webPageURL {
                Link(destination: url) { Text("Open Model Page") }
            }
            Divider()
            Button("Delete…", role: .destructive) { app.requestDelete([name]) }
        } else if !names.isEmpty {
            let updatable = app.updatableNames(names)
            Button("Update \(updatable.count) Models") { app.updateModels(names) }
                .disabled(updatable.isEmpty)
            if names.contains(where: app.isRunning) {
                Button("Unload from Memory") { Task { await app.unloadModels(names) } }
            }
            Divider()
            Button("Delete \(names.count) Models…", role: .destructive) { app.requestDelete(names) }
        }
    }
}
