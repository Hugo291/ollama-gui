import OllamaKit
import SwiftUI

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case vision
    case tools
    case thinking
    case decision
    case embedding
    case cloud

    var id: String { rawValue }

    /// Value of the `c` query parameter on ollama.com.
    var queryValue: String? { self == .all ? nil : rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: LocalizedStringKey("All Capabilities")
        case .vision: LocalizedStringKey("Vision")
        case .tools: LocalizedStringKey("Tools")
        case .thinking: LocalizedStringKey("Thinking")
        case .decision: LocalizedStringKey("Decision")
        case .embedding: LocalizedStringKey("Embedding")
        case .cloud: LocalizedStringKey("Cloud")
        }
    }
}

struct DiscoverView: View {
    private var app: AppModel { .shared }
    private var discover: DiscoverModel { app.discover }

    var body: some View {
        @Bindable var discover = discover

        HSplitView {
            resultsList
                .frame(minWidth: 300, idealWidth: 380, maxWidth: 560)
            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(Text("Discover"))
        .navigationSubtitle(Text(verbatim: "ollama.com"))
        .searchable(text: $discover.query, placement: .toolbar, prompt: Text("Search models on ollama.com"))
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker(selection: $discover.filter) {
                        ForEach(LibraryFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    } label: {
                        Text("Capability")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Label("Capability", systemImage: discover.filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .help(Text("Show only models with a given capability"))
                .accessibilityLabel(Text("Capability"))

                Picker(selection: $discover.sort) {
                    Text("Popular").tag(LibrarySort.popular)
                    Text("Newest").tag(LibrarySort.newest)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .pickerStyle(.segmented)
            }
        }
        .onAppear {
            if !discover.hasSearched { discover.search() }
        }
        .onChange(of: discover.query) { _, _ in discover.search(debounce: true) }
        .onChange(of: discover.filter) { _, _ in discover.search() }
        .onChange(of: discover.sort) { _, _ in discover.search() }
    }

    // MARK: Results

    private var resultsList: some View {
        @Bindable var discover = discover

        return List(selection: $discover.selection) {
            ForEach(discover.results) { model in
                LibraryModelRow(model: model)
                    .tag(model.id)
                    .onAppear {
                        // The end of the list: load the next page.
                        if model.id == discover.results.last?.id { discover.loadMore() }
                    }
            }
            if discover.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.inset)
        .overlay {
            if let error = discover.error {
                ContentUnavailableView {
                    Label("Can't Reach ollama.com", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(verbatim: error)
                } actions: {
                    Button("Try Again") { discover.search() }
                }
            } else if discover.results.isEmpty && discover.isLoading {
                ProgressView()
            } else if discover.results.isEmpty && discover.hasSearched {
                ContentUnavailableView.search(text: discover.query)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let model = discover.results.first(where: { $0.id == discover.selection }) {
            LibraryModelDetail(model: model)
                .id(model.id)
        } else {
            ContentUnavailableView {
                Label("Discover Models", systemImage: "globe")
            } description: {
                Text("Browse the Ollama library and pull models in one click.")
            }
        }
    }
}

private struct LibraryModelRow: View {
    private var app: AppModel { .shared }
    let model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: model.name)
                    .font(.headline)
                if !app.installedTags(of: model).isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .help(Text("Installed"))
                }
                Spacer()
                if let pulls = model.pulls {
                    Label {
                        Text(verbatim: LibraryText.count(pulls, french: app.discover.french))
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                }
            }
            if !model.summary.isEmpty {
                Text(verbatim: model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            FlowLayout(spacing: 4) {
                ForEach(model.capabilities, id: \.self) { capability in
                    Badge(CapabilityStyle.title(capability), tint: CapabilityStyle.tint(capability))
                }
                ForEach(model.sizes, id: \.self) { size in
                    Badge(verbatim: size, tint: .blue)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct LibraryModelDetail: View {
    private var app: AppModel { .shared }
    let model: LibraryModel

    @State private var tags: [LibraryTag] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var tagFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            tagsTable
        }
        .task(id: model.id) { await loadTags() }
    }

    private func loadTags() async {
        isLoading = true
        defer { isLoading = false }
        do {
            tags = try await LibraryClient().tags(for: model)
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: model.name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                Link(destination: model.pageURL) {
                    Label("ollama.com", systemImage: "arrow.up.right.square")
                }
            }
            if !model.summary.isEmpty {
                Text(verbatim: model.summary)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                if let pulls = model.pulls {
                    Label {
                        Text("\(LibraryText.count(pulls, french: app.discover.french)) pulls")
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                if let tagCount = model.tagCount {
                    Label {
                        if let count = Int(tagCount) {
                            Text("\(count) tags")
                        } else {
                            Text("\(tagCount) tags")
                        }
                    } icon: {
                        Image(systemName: "tag")
                    }
                }
                if let updated = model.updated {
                    Label {
                        Text(verbatim: LibraryText.age(updated, french: app.discover.french))
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            FlowLayout(spacing: 4) {
                ForEach(model.capabilities, id: \.self) { capability in
                    Badge(CapabilityStyle.title(capability), tint: CapabilityStyle.tint(capability))
                }
            }
        }
    }

    private var filteredTags: [LibraryTag] {
        let query = tagFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tags }
        return tags.filter { tag in
            tag.name.localizedCaseInsensitiveContains(query) || tag.badges.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    @ViewBuilder
    private var tagsTable: some View {
        if isLoading && tags.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, tags.isEmpty {
            ContentUnavailableView {
                Label("Can't Load Tags", systemImage: "tag.slash")
            } description: {
                Text(verbatim: error)
            } actions: {
                Button("Try Again") { Task { await loadTags() } }
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("Tags")
                        .font(.headline)
                    Spacer()
                    TextField("Filter tags", text: $tagFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Table(filteredTags) {
                    TableColumn("Tag") { tag in
                        HStack(spacing: 6) {
                            Text(verbatim: tag.tag)
                                .font(.system(.body, design: .monospaced))
                            ForEach(tag.badges, id: \.self) { badge in
                                Badge(verbatim: badge)
                            }
                        }
                    }
                    .width(min: 100, ideal: 150)
                    TableColumn("Size") { tag in
                        Text(verbatim: tag.size.map { LibraryText.size($0, french: app.discover.french) } ?? "—")
                            .monospacedDigit()
                            .help(Text(verbatim: tag.size.map { LibraryText.size($0, french: app.discover.french) } ?? ""))
                    }
                    .width(min: 56, ideal: 76)
                    TableColumn("Context") { tag in
                        Text(verbatim: shortContext(tag.context))
                    }
                    .width(min: 44, ideal: 60)
                    TableColumn("Input") { tag in
                        Text(verbatim: tag.input.map { LibraryText.input($0, french: app.discover.french) } ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 56, ideal: 90)
                    TableColumn("") { tag in
                        TagAction(tag: tag)
                    }
                    .width(min: 104, ideal: 112)
                }
            }
        }
    }

    private func shortContext(_ context: String?) -> String {
        guard let context else { return "—" }
        return context
            .replacingOccurrences(of: "context window", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Pull button, progress or "installed" mark for one tag.
private struct TagAction: View {
    private var app: AppModel { .shared }
    let tag: LibraryTag

    var body: some View {
        if let download = app.activeDownload(for: tag.name) {
            HStack(spacing: 6) {
                ProgressView(value: download.fractionCompleted ?? 0)
                    .frame(width: 54)
                Button {
                    app.downloads.cancel(download)
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help(Text("Cancel"))
            }
        } else if app.isInstalled(tag.name) {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Button("Pull") {
                app.pull(tag.name)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!app.connection.isConnected)
        }
    }
}
