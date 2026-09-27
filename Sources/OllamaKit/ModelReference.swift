import Foundation

/// A parsed model name: `[host/][namespace/]repository[:tag]`.
///
/// `gemma3` → `registry.ollama.ai/library/gemma3:latest`,
/// `hf.co/unsloth/Qwen3-GGUF:Q4_K_M` → host `hf.co`, namespace `unsloth`.
public struct ModelReference: Hashable, Sendable {
    public static let officialRegistry = "registry.ollama.ai"

    public var host: String
    public var namespace: String
    public var repository: String
    public var tag: String

    public init?(_ name: String) {
        var text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        var parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: \.isEmpty), var last = parts.popLast() else { return nil }

        var tag = "latest"
        if let colon = last.lastIndex(of: ":") {
            tag = String(last[last.index(after: colon)...])
            last = String(last[..<colon])
        }
        guard !tag.isEmpty, !last.isEmpty, !last.contains(":") else { return nil }

        switch parts.count {
        case 0:
            host = Self.officialRegistry
            namespace = "library"
        case 1:
            host = Self.officialRegistry
            namespace = parts[0]
        case 2:
            host = parts[0]
            namespace = parts[1]
        default:
            return nil
        }
        guard Self.isValidComponent(namespace), Self.isValidComponent(last), Self.isValidComponent(tag) else { return nil }
        if host == "ollama.com" { host = Self.officialRegistry }
        repository = last
        self.tag = tag
    }

    private static func isValidComponent(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar)
        }
    }

    public var isOfficialRegistry: Bool { host == Self.officialRegistry }

    /// Cloud models have a `cloud` tag, or a tag ending in `-cloud`.
    public var isCloudTag: Bool { tag == "cloud" || tag.hasSuffix("-cloud") }

    /// The shortest name Ollama accepts for this model (`gemma3:270m`, `user/model:tag`).
    public var shortName: String {
        if isOfficialRegistry {
            return namespace == "library" ? "\(repository):\(tag)" : "\(namespace)/\(repository):\(tag)"
        }
        return "\(host)/\(namespace)/\(repository):\(tag)"
    }

    /// Fully qualified, lower-cased form used to compare names.
    public var canonicalName: String {
        "\(host)/\(namespace)/\(repository):\(tag)".lowercased()
    }

    /// Canonical form of any model name; falls back to the lower-cased input.
    public static func canonical(_ name: String) -> String {
        ModelReference(name)?.canonicalName ?? name.lowercased()
    }

    public var manifestURL: URL? {
        URL(string: "https://\(host)/v2/\(namespace)/\(repository)/manifests/\(tag)")
    }

    /// Public web page of the model, when it comes from a known registry.
    public var webPageURL: URL? {
        switch host {
        case Self.officialRegistry:
            return namespace == "library"
                ? URL(string: "https://ollama.com/library/\(repository)")
                : URL(string: "https://ollama.com/\(namespace)/\(repository)")
        case "hf.co", "huggingface.co":
            return URL(string: "https://huggingface.co/\(namespace)/\(repository)")
        default:
            return nil
        }
    }
}
