import Foundation

// MARK: - Capabilities

/// Capabilities reported by Ollama for a model (`/api/tags`, `/api/show`).
public enum Capability: String, CaseIterable, Sendable {
    case completion
    case vision
    case tools
    case thinking
    case decision
    case embedding
    case image
    case audio
    case insert
}

// MARK: - Model details

public struct ModelDetails: Decodable, Hashable, Sendable {
    public var parentModel: String?
    public var format: String?
    public var family: String?
    public var families: [String]?
    public var parameterSize: String?
    public var quantizationLevel: String?
    public var contextLength: Int?
    public var embeddingLength: Int?

    enum CodingKeys: String, CodingKey {
        case parentModel = "parent_model"
        case format
        case family
        case families
        case parameterSize = "parameter_size"
        case quantizationLevel = "quantization_level"
        case contextLength = "context_length"
        case embeddingLength = "embedding_length"
    }

    public init(
        parentModel: String? = nil,
        format: String? = nil,
        family: String? = nil,
        families: [String]? = nil,
        parameterSize: String? = nil,
        quantizationLevel: String? = nil,
        contextLength: Int? = nil,
        embeddingLength: Int? = nil
    ) {
        self.parentModel = parentModel
        self.format = format
        self.family = family
        self.families = families
        self.parameterSize = parameterSize
        self.quantizationLevel = quantizationLevel
        self.contextLength = contextLength
        self.embeddingLength = embeddingLength
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentModel = try? container.decodeIfPresent(String.self, forKey: .parentModel)
        format = try? container.decodeIfPresent(String.self, forKey: .format)
        family = try? container.decodeIfPresent(String.self, forKey: .family)
        families = try? container.decodeIfPresent([String].self, forKey: .families)
        parameterSize = try? container.decodeIfPresent(String.self, forKey: .parameterSize)
        quantizationLevel = try? container.decodeIfPresent(String.self, forKey: .quantizationLevel)
        contextLength = try? container.decodeIfPresent(Int.self, forKey: .contextLength)
        embeddingLength = try? container.decodeIfPresent(Int.self, forKey: .embeddingLength)
    }
}

// MARK: - Installed model (/api/tags)

public struct OllamaModel: Decodable, Identifiable, Hashable, Sendable {
    public var name: String
    public var model: String?
    public var modifiedAt: Date?
    public var size: Int64
    public var digest: String
    public var details: ModelDetails?
    public var capabilities: [String]?
    public var remoteModel: String?
    public var remoteHost: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case model
        case modifiedAt = "modified_at"
        case size
        case digest
        case details
        case capabilities
        case remoteModel = "remote_model"
        case remoteHost = "remote_host"
    }

    public init(
        name: String,
        modifiedAt: Date? = nil,
        size: Int64 = 0,
        digest: String = "",
        details: ModelDetails? = nil,
        capabilities: [String]? = nil,
        remoteModel: String? = nil,
        remoteHost: String? = nil
    ) {
        self.name = name
        self.model = name
        self.modifiedAt = modifiedAt
        self.size = size
        self.digest = digest
        self.details = details
        self.capabilities = capabilities
        self.remoteModel = remoteModel
        self.remoteHost = remoteHost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let model = try? container.decodeIfPresent(String.self, forKey: .model)
        guard let name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? model else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: container.codingPath, debugDescription: "Model without a name"))
        }
        self.name = name
        self.model = model
        modifiedAt = container.ollamaDate(forKey: .modifiedAt)
        size = (try? container.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        digest = (try? container.decodeIfPresent(String.self, forKey: .digest)) ?? ""
        details = try? container.decodeIfPresent(ModelDetails.self, forKey: .details)
        capabilities = try? container.decodeIfPresent([String].self, forKey: .capabilities)
        remoteModel = try? container.decodeIfPresent(String.self, forKey: .remoteModel)
        remoteHost = try? container.decodeIfPresent(String.self, forKey: .remoteHost)
    }

    // MARK: Derived values

    public var reference: ModelReference? { ModelReference(name) }

    /// Cloud models run on ollama.com; locally they are only a small stub.
    public var isCloud: Bool {
        if let remoteHost, !remoteHost.isEmpty { return true }
        return reference?.isCloudTag ?? false
    }

    public func supports(_ capability: Capability) -> Bool {
        capabilities?.contains(capability.rawValue) ?? false
    }

    /// Older Ollama versions don't report capabilities: assume a text model then.
    public var canChat: Bool {
        guard let capabilities else { return true }
        return capabilities.contains(Capability.completion.rawValue) && !capabilities.contains(Capability.embedding.rawValue)
    }

    /// Whether the model can be preloaded into memory with `keep_alive`.
    public var canLoad: Bool {
        !isCloud && !supports(.image)
    }

    public var parameterSize: String? { details?.parameterSize.nonEmpty }
    public var quantization: String? { details?.quantizationLevel.nonEmpty }
    public var format: String? { details?.format.nonEmpty }
    public var family: String? { details?.family.nonEmpty ?? details?.families?.first.nonEmpty }

    /// Digest without the optional `sha256:` prefix.
    public var shortDigest: String {
        String(digest.replacingOccurrences(of: "sha256:", with: "").prefix(12))
    }
}

// MARK: - Loaded model (/api/ps)

public struct RunningModel: Decodable, Identifiable, Hashable, Sendable {
    public var name: String
    public var model: String?
    public var size: Int64
    public var digest: String?
    public var details: ModelDetails?
    public var expiresAt: Date?
    public var sizeVRAM: Int64
    public var contextLength: Int?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case model
        case size
        case digest
        case details
        case expiresAt = "expires_at"
        case sizeVRAM = "size_vram"
        case contextLength = "context_length"
    }

    public init(name: String, size: Int64, sizeVRAM: Int64, expiresAt: Date? = nil, contextLength: Int? = nil, details: ModelDetails? = nil) {
        self.name = name
        self.model = name
        self.size = size
        self.sizeVRAM = sizeVRAM
        self.expiresAt = expiresAt
        self.contextLength = contextLength
        self.details = details
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let model = try? container.decodeIfPresent(String.self, forKey: .model)
        guard let name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? model else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(codingPath: container.codingPath, debugDescription: "Model without a name"))
        }
        self.name = name
        self.model = model
        size = (try? container.decodeIfPresent(Int64.self, forKey: .size)) ?? 0
        digest = try? container.decodeIfPresent(String.self, forKey: .digest)
        details = try? container.decodeIfPresent(ModelDetails.self, forKey: .details)
        expiresAt = container.ollamaDate(forKey: .expiresAt)
        sizeVRAM = (try? container.decodeIfPresent(Int64.self, forKey: .sizeVRAM)) ?? 0
        contextLength = try? container.decodeIfPresent(Int.self, forKey: .contextLength)
    }

    /// Share of the model held in GPU memory, between 0 and 1.
    public var gpuShare: Double {
        guard size > 0 else { return 0 }
        return min(1, max(0, Double(sizeVRAM) / Double(size)))
    }

    /// Same wording as the `PROCESSOR` column of `ollama ps`.
    public var processorLabel: String {
        if sizeVRAM <= 0 { return "100% CPU" }
        if sizeVRAM >= size { return "100% GPU" }
        // Split between the two: never shown as 0% or 100% on either side.
        let cpu = min(99, max(1, Int((Double(size - sizeVRAM) / Double(size) * 100).rounded())))
        return "\(cpu)%/\(100 - cpu)% CPU/GPU"
    }

    /// Models loaded with a negative keep-alive expire centuries from now.
    public var staysLoaded: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow > 365 * 24 * 3600
    }
}

// MARK: - Model information (/api/show)

public struct TensorInfo: Decodable, Hashable, Sendable {
    public var name: String
    public var type: String?
    public var shape: [Int64]?
}

public struct ModelParameter: Hashable, Identifiable, Sendable {
    public var key: String
    public var value: String
    public var index: Int
    public var id: Int { index }
}

public struct ModelShowResponse: Decodable, Hashable, Sendable {
    public var license: String?
    public var modelfile: String?
    public var parameters: String?
    public var template: String?
    public var system: String?
    public var details: ModelDetails?
    public var modelInfo: [String: JSONValue]?
    public var projectorInfo: [String: JSONValue]?
    public var tensors: [TensorInfo]?
    public var capabilities: [String]?
    public var modifiedAt: Date?
    public var requires: String?
    public var remoteModel: String?
    public var remoteHost: String?

    enum CodingKeys: String, CodingKey {
        case license
        case modelfile
        case parameters
        case template
        case system
        case details
        case modelInfo = "model_info"
        case projectorInfo = "projector_info"
        case tensors
        case capabilities
        case modifiedAt = "modified_at"
        case requires
        case remoteModel = "remote_model"
        case remoteHost = "remote_host"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        license = try? container.decodeIfPresent(String.self, forKey: .license)
        modelfile = try? container.decodeIfPresent(String.self, forKey: .modelfile)
        parameters = try? container.decodeIfPresent(String.self, forKey: .parameters)
        template = try? container.decodeIfPresent(String.self, forKey: .template)
        system = try? container.decodeIfPresent(String.self, forKey: .system)
        details = try? container.decodeIfPresent(ModelDetails.self, forKey: .details)
        modelInfo = try? container.decodeIfPresent([String: JSONValue].self, forKey: .modelInfo)
        projectorInfo = try? container.decodeIfPresent([String: JSONValue].self, forKey: .projectorInfo)
        tensors = try? container.decodeIfPresent([TensorInfo].self, forKey: .tensors)
        capabilities = try? container.decodeIfPresent([String].self, forKey: .capabilities)
        modifiedAt = container.ollamaDate(forKey: .modifiedAt)
        requires = try? container.decodeIfPresent(String.self, forKey: .requires)
        remoteModel = try? container.decodeIfPresent(String.self, forKey: .remoteModel)
        remoteHost = try? container.decodeIfPresent(String.self, forKey: .remoteHost)
    }

    public var architecture: String? {
        modelInfo?["general.architecture"]?.stringValue.nonEmpty ?? details?.family.nonEmpty
    }

    public var contextLength: Int? {
        if let architecture, let value = modelInfo?["\(architecture).context_length"]?.intValue {
            return Int(value)
        }
        return details?.contextLength
    }

    public var embeddingLength: Int? {
        if let architecture, let value = modelInfo?["\(architecture).embedding_length"]?.intValue {
            return Int(value)
        }
        return details?.embeddingLength
    }

    public var parameterCount: Int64? {
        modelInfo?["general.parameter_count"]?.intValue
    }

    /// The `parameters` block parsed into key/value pairs (keys may repeat, e.g. `stop`).
    public var parameterList: [ModelParameter] {
        Self.parseParameters(parameters)
    }

    /// First meaningful line of the license, usually its name.
    public var licenseTitle: String? {
        license?
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    public static func parseParameters(_ text: String?) -> [ModelParameter] {
        guard let text else { return [] }
        var result: [ModelParameter] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let separator = trimmed.firstIndex(where: \.isWhitespace) else {
                result.append(ModelParameter(key: trimmed, value: "", index: result.count))
                continue
            }
            let key = String(trimmed[..<separator])
            var value = trimmed[separator...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            result.append(ModelParameter(key: key, value: value, index: result.count))
        }
        return result
    }
}

// MARK: - Streaming progress (/api/pull, /api/create)

public struct ProgressEvent: Decodable, Hashable, Sendable {
    public var status: String?
    public var digest: String?
    public var total: Int64?
    public var completed: Int64?

    public init(status: String? = nil, digest: String? = nil, total: Int64? = nil, completed: Int64? = nil) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
    }
}

// MARK: - Chat (/api/chat)

public struct ChatMessage: Codable, Hashable, Sendable {
    public var role: String
    public var content: String
    public var thinking: String?
    public var images: [String]?

    public init(role: String, content: String, thinking: String? = nil, images: [String]? = nil) {
        self.role = role
        self.content = content
        self.thinking = thinking
        self.images = images
    }

    enum CodingKeys: String, CodingKey {
        case role, content, thinking, images
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = (try? container.decodeIfPresent(String.self, forKey: .role)) ?? "assistant"
        content = (try? container.decodeIfPresent(String.self, forKey: .content)) ?? ""
        thinking = try? container.decodeIfPresent(String.self, forKey: .thinking)
        images = try? container.decodeIfPresent([String].self, forKey: .images)
    }
}

public struct ChatRequest: Encodable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var stream: Bool
    public var think: Bool?
    public var options: [String: JSONValue]?
    /// Seconds to keep the model in memory after the request.
    public var keepAlive: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, think, options
        case keepAlive = "keep_alive"
    }

    public init(model: String, messages: [ChatMessage], stream: Bool = true, think: Bool? = nil, options: [String: JSONValue]? = nil, keepAlive: Int? = nil) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.think = think
        self.options = options
        self.keepAlive = keepAlive
    }
}

public struct ChatChunk: Decodable, Sendable {
    public var model: String?
    public var message: ChatMessage?
    public var done: Bool
    public var doneReason: String?
    public var totalDuration: Int64?
    public var loadDuration: Int64?
    public var promptEvalCount: Int?
    public var promptEvalDuration: Int64?
    public var evalCount: Int?
    public var evalDuration: Int64?

    enum CodingKeys: String, CodingKey {
        case model, message, done
        case doneReason = "done_reason"
        case totalDuration = "total_duration"
        case loadDuration = "load_duration"
        case promptEvalCount = "prompt_eval_count"
        case promptEvalDuration = "prompt_eval_duration"
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        message = try? container.decodeIfPresent(ChatMessage.self, forKey: .message)
        done = (try? container.decodeIfPresent(Bool.self, forKey: .done)) ?? false
        doneReason = try? container.decodeIfPresent(String.self, forKey: .doneReason)
        totalDuration = try? container.decodeIfPresent(Int64.self, forKey: .totalDuration)
        loadDuration = try? container.decodeIfPresent(Int64.self, forKey: .loadDuration)
        promptEvalCount = try? container.decodeIfPresent(Int.self, forKey: .promptEvalCount)
        promptEvalDuration = try? container.decodeIfPresent(Int64.self, forKey: .promptEvalDuration)
        evalCount = try? container.decodeIfPresent(Int.self, forKey: .evalCount)
        evalDuration = try? container.decodeIfPresent(Int64.self, forKey: .evalDuration)
    }

    /// Generation speed in tokens per second, when the final chunk reports it.
    public var tokensPerSecond: Double? {
        guard let evalCount, let evalDuration, evalDuration > 0 else { return nil }
        return Double(evalCount) / (Double(evalDuration) / 1_000_000_000)
    }
}

// MARK: - Create (/api/create)

public struct CreateModelRequest: Encodable, Sendable {
    public var model: String
    public var from: String
    public var system: String?
    public var template: String?
    public var parameters: [String: JSONValue]?
    public var stream: Bool

    public init(model: String, from: String, system: String? = nil, template: String? = nil, parameters: [String: JSONValue]? = nil, stream: Bool = true) {
        self.model = model
        self.from = from
        self.system = system
        self.template = template
        self.parameters = parameters
        self.stream = stream
    }
}

// MARK: - Envelopes

struct VersionResponse: Decodable {
    var version: String
}

struct TagsResponse: Decodable {
    var models: [OllamaModel]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = (try container.decodeIfPresent([OllamaModel].self, forKey: .models)) ?? []
    }

    enum CodingKeys: String, CodingKey { case models }
}

struct RunningResponse: Decodable {
    var models: [RunningModel]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = (try container.decodeIfPresent([RunningModel].self, forKey: .models)) ?? []
    }

    enum CodingKeys: String, CodingKey { case models }
}

struct APIErrorBody: Decodable {
    var error: String?
}

// MARK: - Helpers

extension Optional where Wrapped == String {
    /// `nil` when the string is missing or blank.
    var nonEmpty: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
