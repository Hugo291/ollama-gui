import CryptoKit
import Foundation

public enum UpdateStatus: Hashable, Sendable {
    case checking
    case upToDate
    case available
    /// The model can't be checked (custom model, other registry, network error…).
    case unknown(String?)
}

/// Checks the Ollama registry for newer versions of installed models.
///
/// The digest of a local model is the SHA-256 of its manifest, so comparing it with the
/// digest of the registry's current manifest tells whether a pull would change anything.
public struct RegistryClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func status(for model: OllamaModel) async -> UpdateStatus {
        guard !model.isCloud, let reference = model.reference, reference.isOfficialRegistry else {
            return .unknown(nil)
        }
        let local = model.digest.replacingOccurrences(of: "sha256:", with: "").lowercased()
        do {
            let remote = try await remoteDigest(for: reference)
            return remote == local ? .upToDate : .available
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    public func remoteDigest(for reference: ModelReference) async throws -> String {
        guard let url = reference.manifestURL else { throw OllamaError.invalidServerURL }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.docker.distribution.manifest.v2+json", forHTTPHeaderField: "Accept")

        // The registry exposes the digest as a header: a HEAD request is enough.
        request.httpMethod = "HEAD"
        let (_, headResponse) = try await session.data(for: request)
        if let http = headResponse as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw OllamaError.http(status: http.statusCode, message: nil)
            }
            let header = http.value(forHTTPHeaderField: "Ollama-Content-Digest") ?? http.value(forHTTPHeaderField: "Docker-Content-Digest")
            if let header, !header.isEmpty {
                return header.replacingOccurrences(of: "sha256:", with: "").lowercased()
            }
        }

        // Fallback: hash the manifest ourselves.
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try OllamaClient.validate(response, data: data)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
