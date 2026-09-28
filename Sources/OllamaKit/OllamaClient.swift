import Foundation

/// Client for the Ollama REST API (https://docs.ollama.com/api).
public struct OllamaClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public static let defaultPort = 11434

    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Long idle timeout: a pull can stay silent while Ollama verifies a large blob,
        // and loading a big model before the first token can take minutes.
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 16
        return URLSession(configuration: configuration)
    }()

    /// Like `defaultSession`, without any proxy: requests to this Mac go straight to Ollama.
    public static let loopbackSession: URLSession = {
        let configuration = defaultSession.configuration
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
        ]
        return URLSession(configuration: configuration)
    }()

    public init(baseURL: URL, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.session = session ?? (Self.isLoopback(baseURL) ? Self.loopbackSession : Self.defaultSession)
    }

    /// Turns a user supplied address (`localhost`, `192.168.1.20:11434`, `https://ollama.example.com`)
    /// into a base URL. Without a port, plain HTTP uses Ollama's default port 11434.
    ///
    /// Also understood: a bare IPv6 address (`::1`), a port alone (`:8080`, this Mac), the bind
    /// addresses `0.0.0.0` and `[::]` (this Mac), and a trailing `/api` copied from the API
    /// docs. An explicit port, even 80, is kept. User names and passwords stay in the URL for
    /// the requests; `displayString(for:)` hides them.
    public static func baseURL(from input: String) -> URL? {
        normalizedURL(input, defaultHTTPPort: defaultPort)
    }

    /// The `OLLAMA_HOST` variable, read like the Ollama CLI does: `http://host` without a port
    /// means port 80, and a bare host means port 11434.
    public static func baseURL(fromEnvironment value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedURL(trimmed, defaultHTTPPort: trimmed.contains("://") ? 80 : defaultPort)
    }

    private static func normalizedURL(_ input: String, defaultHTTPPort: Int) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if let separator = text.range(of: "://") {
            let scheme = text[..<separator.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            text = scheme + text[separator.lowerBound...]
        } else {
            let hostPart = text.prefix { $0 != "/" }
            let port = hostPart.dropFirst()
            if hostPart.hasPrefix(":"), !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) {
                // A port alone: this Mac.
                text = "127.0.0.1" + text
            } else if !hostPart.hasPrefix("["), hostPart.filter({ $0 == ":" }).count >= 2 {
                // A bare IPv6 address.
                text = "[" + hostPart + "]" + text.dropFirst(hostPart.count)
            }
            text = "http://" + text
        }
        guard var components = URLComponents(string: text),
              let host = components.percentEncodedHost?.lowercased(), !host.isEmpty
        else { return nil }
        components.percentEncodedHost = host
        // Bind addresses: connect through the loopback interface instead.
        if host == "0.0.0.0" {
            components.percentEncodedHost = "127.0.0.1"
        } else if host == "[::]" {
            components.percentEncodedHost = "[::1]"
        }
        if components.port == nil, components.scheme == "http" {
            components.port = defaultHTTPPort
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/api") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The URL as shown to people: without a user name or password.
    public static func displayString(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.user = nil
        components.password = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// Whether the URL points to this Mac.
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedHost?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "[::1]"].contains(host)
    }

    // MARK: - Endpoints

    public func version() async throws -> String {
        let data = try await send(request("api/version", timeout: 4))
        return try decode(VersionResponse.self, from: data).version
    }

    public func models() async throws -> [OllamaModel] {
        let data = try await send(request("api/tags", timeout: 30))
        return try decode(TagsResponse.self, from: data).models
    }

    public func runningModels() async throws -> [RunningModel] {
        let data = try await send(request("api/ps", timeout: 15))
        return try decode(RunningResponse.self, from: data).models
    }

    public func show(_ model: String) async throws -> ModelShowResponse {
        let body: [String: JSONValue] = ["model": .string(model)]
        let data = try await send(request("api/show", method: "POST", body: body, timeout: 60))
        return try decode(ModelShowResponse.self, from: data)
    }

    public func delete(_ model: String) async throws {
        let body: [String: JSONValue] = ["model": .string(model)]
        _ = try await send(request("api/delete", method: "DELETE", body: body, timeout: 120))
    }

    public func copy(from source: String, to destination: String) async throws {
        let body: [String: JSONValue] = ["source": .string(source), "destination": .string(destination)]
        _ = try await send(request("api/copy", method: "POST", body: body, timeout: 120))
    }

    /// Loads a model into memory and keeps it there for `keepAlive` seconds.
    public func load(_ model: String, keepAlive: Int, isEmbedding: Bool) async throws {
        let request: URLRequest
        if isEmbedding {
            let body: [String: JSONValue] = ["model": .string(model), "input": .array([]), "keep_alive": .number(Double(keepAlive))]
            request = try self.request("api/embed", method: "POST", body: body, timeout: 900)
        } else {
            let body: [String: JSONValue] = ["model": .string(model), "keep_alive": .number(Double(keepAlive))]
            request = try self.request("api/generate", method: "POST", body: body, timeout: 900)
        }
        _ = try await send(request)
    }

    /// Unloads a model from memory (works for text and embedding models).
    public func unload(_ model: String) async throws {
        let body: [String: JSONValue] = ["model": .string(model), "keep_alive": .number(0)]
        _ = try await send(request("api/generate", method: "POST", body: body, timeout: 120))
    }

    /// Downloads (or updates) a model. The stream finishes after the final `success` event.
    public func pull(_ model: String) -> AsyncThrowingStream<ProgressEvent, Error> {
        let body: [String: JSONValue] = ["model": .string(model), "stream": .bool(true)]
        return stream("api/pull", body: body, as: ProgressEvent.self)
    }

    public func create(_ create: CreateModelRequest) -> AsyncThrowingStream<ProgressEvent, Error> {
        stream("api/create", body: create, as: ProgressEvent.self)
    }

    public func chat(_ chat: ChatRequest) -> AsyncThrowingStream<ChatChunk, Error> {
        stream("api/chat", body: chat, as: ChatChunk.self)
    }

    // MARK: - Plumbing

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        return request
    }

    private func request(_ path: String, method: String, body: some Encodable, timeout: TimeInterval) throws -> URLRequest {
        var request = request(path, method: method, timeout: timeout)
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OllamaError.unexpectedResponse
        }
    }

    static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        throw OllamaError.http(status: http.statusCode, message: OllamaError.message(fromBody: data))
    }

    /// POSTs `body` and decodes the newline-delimited JSON response line by line.
    private func stream<Event: Decodable & Sendable>(_ path: String, body: some Encodable, as eventType: Event.Type) -> AsyncThrowingStream<Event, Error> {
        let request: URLRequest
        do {
            request = try self.request(path, method: "POST", body: body, timeout: 3600)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 64_000 { break }
                        }
                        throw OllamaError.http(status: http.statusCode, message: OllamaError.message(fromBody: data))
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let data = Data(line.utf8)
                        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        if let message = OllamaError.message(inJSON: data) {
                            throw OllamaError.server(message)
                        }
                        guard let event = try? decoder.decode(Event.self, from: data) else {
                            throw OllamaError.unexpectedResponse
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
