import Foundation
import OllamaKit
import Observation

struct GenerationStats: Equatable {
    var tokensPerSecond: Double?
    var evalCount: Int?
    var promptEvalCount: Int?
    var loadDuration: TimeInterval?
    var totalDuration: TimeInterval?
}

struct PlaygroundMessage: Identifiable, Equatable {
    enum Role: String {
        case user
        case assistant
    }

    let id = UUID()
    var role: Role
    var content: String
    var thinking = ""
    var images: [Data] = []
    var model: String?
    var stats: GenerationStats?
    var error: String?
    var isStreaming = false
}

/// State of the chat playground, kept while navigating between sections.
@MainActor
@Observable
final class PlaygroundModel {
    var modelName = ""
    var messages: [PlaygroundMessage] = []
    var draft = ""
    var attachments: [Data] = []
    var systemPrompt = ""
    var overrideTemperature = false
    var temperature = 0.7
    /// Context window override (`num_ctx`); 0 keeps the model default.
    var contextLength = 0
    var thinkingEnabled = true

    private(set) var isGenerating = false
    @ObservationIgnored private var generationTask: Task<Void, Never>?

    var canSend: Bool {
        !isGenerating && !modelName.isEmpty
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send(using client: OllamaClient, keepAlive: Int, supportsThinking: Bool) {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(PlaygroundMessage(role: .user, content: text, images: attachments))
        draft = ""
        attachments = []

        var history: [ChatMessage] = []
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            history.append(ChatMessage(role: "system", content: system))
        }
        for message in messages where message.error == nil && !(message.role == .assistant && message.content.isEmpty) {
            history.append(ChatMessage(
                role: message.role.rawValue,
                content: message.content,
                images: message.images.isEmpty ? nil : message.images.map { $0.base64EncodedString() }
            ))
        }

        var options: [String: JSONValue] = [:]
        if overrideTemperature { options["temperature"] = .number(temperature) }
        if contextLength > 0 { options["num_ctx"] = .number(Double(contextLength)) }

        let request = ChatRequest(
            model: modelName,
            messages: history,
            think: supportsThinking ? thinkingEnabled : nil,
            options: options.isEmpty ? nil : options,
            keepAlive: keepAlive
        )

        let reply = PlaygroundMessage(role: .assistant, content: "", model: modelName, isStreaming: true)
        messages.append(reply)
        isGenerating = true
        generationTask = Task { [weak self] in
            do {
                for try await chunk in client.chat(request) {
                    self?.apply(chunk, to: reply.id)
                }
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                self?.update(reply.id) { $0.error = error.localizedDescription }
            }
            self?.update(reply.id) { $0.isStreaming = false }
            self?.isGenerating = false
            self?.generationTask = nil
        }
    }

    func stop() {
        generationTask?.cancel()
    }

    func clear() {
        stop()
        messages = []
    }

    private func apply(_ chunk: ChatChunk, to id: UUID) {
        update(id) { message in
            if let content = chunk.message?.content { message.content += content }
            if let thinking = chunk.message?.thinking { message.thinking += thinking }
            if chunk.done {
                message.stats = GenerationStats(
                    tokensPerSecond: chunk.tokensPerSecond,
                    evalCount: chunk.evalCount,
                    promptEvalCount: chunk.promptEvalCount,
                    loadDuration: chunk.loadDuration.map { Double($0) / 1_000_000_000 },
                    totalDuration: chunk.totalDuration.map { Double($0) / 1_000_000_000 }
                )
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout PlaygroundMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }
}
