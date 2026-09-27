import Foundation

public enum OllamaError: LocalizedError, Equatable, Sendable {
    /// The configured server address can't be turned into a URL.
    case invalidServerURL
    /// The server answered with a non-2xx status.
    case http(status: Int, message: String?)
    /// The server reported an error inside a streamed response.
    case server(String)
    /// The response couldn't be decoded.
    case unexpectedResponse
    /// A stream ended without its final "success" message.
    case incompleteStream

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return String(localized: "The server address is not valid.")
        case .http(let status, let message):
            if let message, !message.isEmpty { return message }
            return String(localized: "The server responded with HTTP status \(status).")
        case .server(let message):
            return message
        case .unexpectedResponse:
            return String(localized: "The server sent an unexpected response.")
        case .incompleteStream:
            return String(localized: "The operation ended before it completed.")
        }
    }

    /// Extracts `{"error": "…"}` from a JSON body.
    static func message(inJSON data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) else { return nil }
        return body.error.nonEmpty
    }

    /// Error message of a failed response: JSON `error` field, or the raw body.
    static func message(fromBody data: Data) -> String? {
        if let message = message(inJSON: data) { return message }
        guard let text = String(data: data.prefix(2_000), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
