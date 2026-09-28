import AppKit
import OllamaKit
import SwiftUI
import UniformTypeIdentifiers

struct PlaygroundView: View {
    private var app: AppModel { .shared }
    @State private var showOptions = false

    var body: some View {
        @Bindable var playground = app.playground

        VStack(spacing: 0) {
            if !app.connection.isConnected && playground.messages.isEmpty {
                ServerUnavailableView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playground.messages.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Transcript()
                    // Links written by a model open only when they are web pages.
                    .environment(\.openURL, OpenURLAction { url in
                        ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
                    })
            }
            Divider()
            Composer()
        }
        .navigationTitle(Text("Playground"))
        .navigationSubtitle(Text(verbatim: playground.modelName))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showOptions.toggle()
                } label: {
                    Label("Options", systemImage: "slider.horizontal.3")
                }
                .help(Text("System prompt and generation options"))
                .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                    PlaygroundOptions()
                }

                Button {
                    playground.clear()
                } label: {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
                .help(Text("Start a new conversation"))
                .disabled(playground.messages.isEmpty)
            }
        }
        .onAppear(perform: selectDefaultModel)
        .onChange(of: app.models) { _, _ in selectDefaultModel() }
    }

    /// Picks a model when none is chosen, or when the chosen one is no longer installed
    /// (deleted, or another server), unless a reply is being generated.
    private func selectDefaultModel() {
        let playground = app.playground
        let chatModels = app.models.filter(\.canChat)
        guard playground.modelName.isEmpty
            || (app.hasLoadedModels && !playground.isGenerating && !chatModels.contains { $0.name == playground.modelName })
        else { return }
        let running = chatModels.first { app.isRunning($0.name) }
        playground.modelName = (running ?? chatModels.first { !$0.isCloud } ?? chatModels.first)?.name ?? ""
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Try a Model", systemImage: "text.bubble")
        } description: {
            if app.playground.modelName.isEmpty {
                Text("Choose a model below, then send a message.")
            } else {
                Text("Send a message to \(app.playground.modelName). Replies stream in with their speed in tokens per second.")
            }
        }
    }
}

// MARK: - Transcript

private struct Transcript: View {
    private var app: AppModel { .shared }

    var body: some View {
        let messages = app.playground.messages
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(messages) { message in
                        MessageView(message: message)
                            .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(20)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.last?.content) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

private struct MessageView: View {
    let message: PlaygroundMessage
    @State private var showThinking = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.images.isEmpty {
                        HStack {
                            ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                                ImageThumbnail(data: data, size: 90)
                            }
                        }
                    }
                    if !message.content.isEmpty {
                        Text(verbatim: message.content)
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let model = message.model {
                    Label {
                        Text(verbatim: model)
                    } icon: {
                        Image(systemName: "square.stack.3d.up.fill")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                if !message.thinking.isEmpty {
                    DisclosureGroup(isExpanded: $showThinking) {
                        Text(verbatim: message.thinking)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Label(message.isStreaming && message.content.isEmpty ? LocalizedStringKey("Thinking…") : LocalizedStringKey("Thoughts"), systemImage: "brain")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if !message.content.isEmpty {
                    MarkdownText(text: message.content)
                } else if message.isStreaming && message.thinking.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else if !message.isStreaming && message.error == nil {
                    Text("The model returned an empty reply.")
                        .italic()
                        .foregroundStyle(.secondary)
                }
                if let error = message.error {
                    Label {
                        Text(verbatim: error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.red)
                    .font(.callout)
                }
                HStack(spacing: 12) {
                    if let stats = message.stats {
                        StatsLine(stats: stats)
                    }
                    if !message.isStreaming, !message.content.isEmpty {
                        CopyButton(text: message.content)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct StatsLine: View {
    let stats: GenerationStats

    var body: some View {
        HStack(spacing: 12) {
            if let speed = stats.tokensPerSecond, (stats.evalCount ?? 0) > 1 {
                Label {
                    Text("\(speed, format: .number.precision(.fractionLength(1))) tokens/s")
                } icon: {
                    Image(systemName: "speedometer")
                }
            }
            if let count = stats.evalCount {
                Label {
                    Text("\(count) tokens")
                } icon: {
                    Image(systemName: "number")
                }
            }
            if let total = stats.totalDuration {
                Label {
                    Text(Duration.seconds(total).formatted(.units(allowed: [.minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2)))
                } icon: {
                    Image(systemName: "timer")
                }
            }
            if let load = stats.loadDuration, load > 0.5 {
                Label {
                    Text("Loaded in \(Duration.seconds(load).formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1))))")
                } icon: {
                    Image(systemName: "memorychip")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }
}

/// Renders a reply's Markdown: paragraphs, headings, code, quotes, lists, tables and rules.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.blocks(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            InlineMarkdown(text: text)
        case .heading(let level, let text):
            InlineMarkdown(text: text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 2)
        case .code(_, let text):
            CodeBlock(text: text, maxHeight: 400)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.tertiary)
                    .frame(width: 3)
                InlineMarkdown(text: text)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: item.number.map { "\($0)." } ?? (item.level == 0 ? "•" : "◦"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        InlineMarkdown(text: item.text)
                    }
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Divider()
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        InlineMarkdown(text: cell)
                            .fontWeight(.semibold)
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            InlineMarkdown(text: cell)
                        }
                    }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.automatic)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Bold, italic, inline code, strikethrough and links; line breaks are kept.
private struct InlineMarkdown: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

private struct ImageThumbnail: View {
    let data: Data
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Composer

private struct PlaygroundModelPicker: View {
    private var app: AppModel { .shared }

    var body: some View {
        @Bindable var playground = app.playground
        let models = app.models.filter(\.canChat)

        Picker(selection: $playground.modelName) {
            if playground.modelName.isEmpty {
                Text("Choose a Model").tag("")
            }
            ForEach(models) { model in
                Text(verbatim: model.name).tag(model.name)
            }
            if !playground.modelName.isEmpty, !models.contains(where: { $0.name == playground.modelName }) {
                Text(verbatim: playground.modelName).tag(playground.modelName)
            }
        } label: {
            Text("Model")
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help(Text("Model used for the next message"))
    }
}

private struct Composer: View {
    private var app: AppModel { .shared }
    @FocusState private var focused: Bool
    @State private var importing = false

    var body: some View {
        @Bindable var playground = app.playground

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PlaygroundModelPicker()
                if let hint {
                    hint
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            if !playground.attachments.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(playground.attachments.enumerated()), id: \.offset) { index, data in
                        ImageThumbnail(data: data)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    playground.attachments.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .padding(3)
                            }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                if supportsVision {
                    Button {
                        importing = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Attach images"))
                    .accessibilityLabel(Text("Attach images"))
                }

                TextField("Message", text: $playground.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator))

                if playground.isGenerating {
                    Button {
                        playground.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.title)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(".", modifiers: .command)
                    .help(Text("Stop generating"))
                    .accessibilityLabel(Text("Stop generating"))
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!playground.canSend || !app.connection.isConnected)
                    .help(Text("Send"))
                    .accessibilityLabel(Text("Send"))
                }
            }
        }
        .padding(12)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            attach(urls)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard supportsVision else { return false }
            let images = urls.filter { url in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
            }
            attach(images)
            return !images.isEmpty
        }
        .onAppear { focused = true }
        // Images only go to models that can see them.
        .onChange(of: supportsVision) { _, supports in
            if !supports { playground.attachments = [] }
        }
    }

    private static let maxImages = 8
    private static let maxImageBytes = 20_000_000

    /// Adds images to the next message: at most 8, of 20 MB each, that macOS can read as images.
    private func attach(_ urls: [URL]) {
        let playground = app.playground
        guard supportsVision else { return }
        var problems: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            guard playground.attachments.count < Self.maxImages else {
                problems.append(String(localized: "At most 8 images per message."))
                break
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Self.maxImageBytes else {
                problems.append(String(localized: "\(name) is larger than 20 MB."))
                continue
            }
            guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else {
                problems.append(String(localized: "\(name) couldn't be read as an image."))
                continue
            }
            playground.attachments.append(data)
        }
        if !problems.isEmpty {
            app.errorAlert = ErrorAlert(title: String(localized: "Some images weren't attached"), message: problems.joined(separator: "\n"))
        }
    }

    private var selectedModel: OllamaModel? {
        app.model(named: app.playground.modelName)
    }

    private var supportsVision: Bool {
        selectedModel?.supports(.vision) ?? false
    }

    private var hint: Text? {
        guard let model = selectedModel else { return nil }
        if model.isCloud {
            return Text("Cloud model: runs on ollama.com and requires signing in with `ollama signin`.")
        }
        if !app.isRunning(model.name) {
            return Text("The first message loads the model into memory; it stays loaded for \(KeepAliveOption.title(for: app.settings.keepAliveSeconds)) after the last reply.")
        }
        return nil
    }

    private func send() {
        guard let model = selectedModel ?? app.models.first(where: { $0.name == app.playground.modelName }) else {
            app.playground.send(using: app.client, keepAlive: app.settings.keepAliveSeconds, supportsThinking: false)
            return
        }
        app.playground.send(using: app.client, keepAlive: app.settings.keepAliveSeconds, supportsThinking: model.supports(.thinking))
    }
}

// MARK: - Options

private struct PlaygroundOptions: View {
    private var app: AppModel { .shared }

    private static let contextChoices = [0, 2048, 4096, 8192, 16384, 32768, 65536, 131072]

    var body: some View {
        @Bindable var playground = app.playground
        let supportsThinking = app.model(named: playground.modelName)?.supports(.thinking) ?? false

        Form {
            Section("System Prompt") {
                TextEditor(text: $playground.systemPrompt)
                    .font(.body)
                    .frame(height: 90)
            }
            Section("Generation") {
                Toggle("Custom temperature", isOn: $playground.overrideTemperature)
                if playground.overrideTemperature {
                    LabeledContent {
                        HStack {
                            Slider(value: $playground.temperature, in: 0...2)
                            Text(playground.temperature, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    } label: {
                        Text("Temperature")
                    }
                }
                Picker("Context window", selection: $playground.contextLength) {
                    ForEach(Self.contextChoices, id: \.self) { value in
                        if value == 0 {
                            Text("Model default").tag(0)
                        } else {
                            Text(verbatim: Format.tokens(value)).tag(value)
                        }
                    }
                }
                if supportsThinking {
                    Toggle("Thinking", isOn: $playground.thinkingEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}
