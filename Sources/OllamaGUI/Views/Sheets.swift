import OllamaKit
import SwiftUI

// MARK: - Pull

struct PullModelSheet: View {
    private var app: AppModel { .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(initialName: String) {
        _name = State(initialValue: initialName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { ModelReference(trimmed) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pull a Model")
                .font(.title2.weight(.semibold))
            Text("Enter the name of a model from the Ollama library, optionally followed by a tag.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Model name", text: $name, prompt: Text(verbatim: "llama3.2:3b"))
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(submit)

            Group {
                if !trimmed.isEmpty && !isValid {
                    Label("This isn't a valid model name.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if isValid && app.isInstalled(trimmed) {
                    Label("Already installed: pulling it again updates it to the latest version.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Examples: `gemma3`, `qwen3:8b`, `hf.co/unsloth/Qwen3-8B-GGUF:Q4_K_M`")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            HStack {
                Button("Browse the Library…") {
                    dismiss()
                    app.section = .discover
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Pull", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || !app.connection.isConnected)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 480)
    }

    private func submit() {
        guard isValid, app.connection.isConnected else { return }
        app.pull(trimmed)
        dismiss()
        app.section = .downloads
    }
}

// MARK: - Duplicate / rename

struct CopyModelSheet: View {
    private var app: AppModel { .shared }
    @Environment(\.dismiss) private var dismiss
    let request: CopyRequest

    @State private var destination = ""
    @State private var isWorking = false
    @State private var error: String?

    private var trimmed: String { destination.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isRename: Bool { request.mode == .rename }

    private var validation: Text? {
        guard !trimmed.isEmpty else { return nil }
        guard ModelReference(trimmed) != nil else { return Text("This isn't a valid model name.") }
        if ModelReference.canonical(trimmed) == ModelReference.canonical(request.source) {
            return Text("Choose a different name.")
        }
        if app.isInstalled(trimmed) {
            return Text("A model with this name already exists and will be replaced.")
        }
        return nil
    }

    private var canSubmit: Bool {
        !isWorking && ModelReference(trimmed) != nil
            && ModelReference.canonical(trimmed) != ModelReference.canonical(request.source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isRename ? LocalizedStringKey("Rename Model") : LocalizedStringKey("Duplicate Model"))
                .font(.title2.weight(.semibold))
            Text(isRename
                 ? LocalizedStringKey("Ollama has no rename: the model is copied under the new name, then the original name is removed. No data is downloaded again.")
                 : LocalizedStringKey("The copy shares its data with the original, so it takes no extra disk space. Useful to give a model a shorter name."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Model") {
                Text(verbatim: request.source)
                    .font(.system(.body, design: .monospaced))
            }
            TextField("New name", text: $destination)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(submit)

            if let validation {
                validation
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error {
                Text(verbatim: error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? LocalizedStringKey("Rename") : LocalizedStringKey("Duplicate"), action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            destination = isRename ? request.source : Self.suggestedCopyName(for: request.source)
        }
    }

    private static func suggestedCopyName(for source: String) -> String {
        guard let reference = ModelReference(source) else { return source + "-copy" }
        let base = reference.isOfficialRegistry && reference.namespace == "library"
            ? reference.repository
            : reference.shortName.components(separatedBy: ":").first ?? reference.repository
        return "\(base)-copy:\(reference.tag)"
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        error = nil
        Task {
            do {
                if isRename {
                    try await app.rename(from: request.source, to: trimmed)
                } else {
                    try await app.copy(from: request.source, to: trimmed)
                    app.reveal(app.models.first { ModelReference.canonical($0.name) == ModelReference.canonical(trimmed) }?.name ?? trimmed)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Customize (create)

struct CreateModelSheet: View {
    private var app: AppModel { .shared }
    @Environment(\.dismiss) private var dismiss
    let request: CreateRequest

    @State private var name = ""
    @State private var base = ""
    @State private var systemPrompt = ""
    @State private var useTemperature = false
    @State private var temperature = 0.7
    @State private var useContext = false
    @State private var contextLength = 8192
    @State private var useTopP = false
    @State private var topP = 0.9
    @State private var useSeed = false
    @State private var seed = 42

    @State private var isWorking = false
    @State private var status = ""
    @State private var error: String?

    private static let contextChoices = [2048, 4096, 8192, 16384, 32768, 65536, 131072, 262144]

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var baseModels: [OllamaModel] {
        app.models.filter { !$0.isCloud && $0.canChat }
    }

    private var canSubmit: Bool {
        !isWorking && !base.isEmpty && ModelReference(trimmedName) != nil
            && ModelReference.canonical(trimmedName) != ModelReference.canonical(base)
            && (!useSeed || seed >= 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Customize a Model")
                    .font(.title2.weight(.semibold))
                Text("Creates a new model on top of an existing one, with its own system prompt and parameters. The weights are shared, so it takes almost no disk space.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    Picker("Based on", selection: $base) {
                        ForEach(baseModels) { model in
                            Text(verbatim: model.name).tag(model.name)
                        }
                    }
                    TextField("Name", text: $name, prompt: Text(verbatim: "my-assistant:latest"))
                }
                Section("System Prompt") {
                    TextEditor(text: $systemPrompt)
                        .font(.body)
                        .frame(minHeight: 100)
                }
                Section("Parameters") {
                    Toggle("Temperature", isOn: $useTemperature)
                    if useTemperature {
                        HStack {
                            Slider(value: $temperature, in: 0...2)
                            Text(temperature, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    Toggle("Context window", isOn: $useContext)
                    if useContext {
                        Picker("Tokens", selection: $contextLength) {
                            ForEach(Self.contextChoices, id: \.self) { value in
                                Text(verbatim: Format.tokens(value)).tag(value)
                            }
                        }
                    }
                    Toggle("Top P", isOn: $useTopP)
                    if useTopP {
                        HStack {
                            Slider(value: $topP, in: 0...1)
                            Text(topP, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    Toggle("Fixed seed", isOn: $useSeed)
                    if useSeed {
                        TextField("Seed", value: $seed, format: .number.grouping(.never))
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let error {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(20)
        }
        .frame(width: 540, height: 640)
        .onAppear(perform: prefill)
        .onChange(of: base) { _, _ in loadBaseSystemPrompt() }
    }

    /// `gemma3-custom:latest`, or `gemma3-custom-2:latest`… when that name is taken.
    private func prefill() {
        base = request.base
        let repository = ModelReference(request.base)?.repository ?? "model"
        var candidate = "\(repository)-custom:latest"
        var number = 2
        while app.isInstalled(candidate) {
            candidate = "\(repository)-custom-\(number):latest"
            number += 1
        }
        name = candidate
    }

    private func loadBaseSystemPrompt() {
        guard systemPrompt.isEmpty, let model = app.model(named: base) else { return }
        Task {
            if let info = try? await app.details(for: model), let system = info.system, systemPrompt.isEmpty {
                systemPrompt = system
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        var parameters: [String: JSONValue] = [:]
        if useTemperature { parameters["temperature"] = .number((temperature * 100).rounded() / 100) }
        if useContext { parameters["num_ctx"] = .number(Double(contextLength)) }
        if useTopP { parameters["top_p"] = .number((topP * 100).rounded() / 100) }
        if useSeed { parameters["seed"] = .number(Double(seed)) }
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let createRequest = CreateModelRequest(
            model: trimmedName,
            from: base,
            system: system.isEmpty ? nil : system,
            parameters: parameters.isEmpty ? nil : parameters
        )

        isWorking = true
        error = nil
        status = ""
        let client = app.client
        Task {
            do {
                var succeeded = false
                for try await event in client.create(createRequest) {
                    if let value = event.status {
                        status = Format.progressStatus(value)
                        if value == "success" { succeeded = true }
                    }
                }
                guard succeeded else { throw OllamaError.incompleteStream }
                await app.refreshModels()
                if let created = app.models.first(where: { ModelReference.canonical($0.name) == ModelReference.canonical(trimmedName) }) {
                    app.reveal(created.name)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }
}
