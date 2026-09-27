import Foundation

/// A model family listed on ollama.com.
public struct LibraryModel: Identifiable, Hashable, Sendable {
    /// Path on ollama.com: `library/qwen3` or `user/model`.
    public var path: String
    public var name: String
    public var summary: String
    public var capabilities: [String]
    public var sizes: [String]
    public var pulls: String?
    public var tagCount: String?
    public var updated: String?

    public var id: String { path }

    public init(path: String, name: String, summary: String = "", capabilities: [String] = [], sizes: [String] = [], pulls: String? = nil, tagCount: String? = nil, updated: String? = nil) {
        self.path = path
        self.name = name
        self.summary = summary
        self.capabilities = capabilities
        self.sizes = sizes
        self.pulls = pulls
        self.tagCount = tagCount
        self.updated = updated
    }

    public var pageURL: URL { LibraryClient.baseURL.appending(path: path) }

    /// Name to pass to `ollama pull` (without tag).
    public var pullName: String {
        path.hasPrefix("library/") ? String(path.dropFirst("library/".count)) : path
    }
}

/// One tag of a library model, e.g. `qwen3:8b`.
public struct LibraryTag: Identifiable, Hashable, Sendable {
    /// Name to pull, e.g. `qwen3:8b`.
    public var name: String
    public var badges: [String]
    public var digest: String?
    /// Download size (`5.2GB`), or the usage level for cloud models.
    public var size: String?
    public var context: String?
    public var input: String?
    public var updated: String?

    public var id: String { name }

    public var tag: String {
        name.split(separator: ":").last.map(String.init) ?? "latest"
    }

    public var isCloud: Bool { tag == "cloud" || tag.hasSuffix("-cloud") }
}

public enum LibrarySort: String, CaseIterable, Sendable {
    case popular
    case newest
}

/// Reads the public model library of ollama.com.
///
/// ollama.com has no public search API, so this parses the HTML of the search and tags
/// pages. Parsing is deliberately lenient: unknown markup yields fewer fields, not errors.
public struct LibraryClient: Sendable {
    public static let baseURL = URL(string: "https://ollama.com")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// `capability` is one of `vision`, `tools`, `thinking`, `embedding`, `cloud`.
    public func search(query: String, capability: String? = nil, sort: LibrarySort = .popular) async throws -> [LibraryModel] {
        var components = URLComponents(url: Self.baseURL.appending(path: "search"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: query)]
        if let capability {
            items.append(URLQueryItem(name: "c", value: capability))
        }
        if sort != .popular {
            items.append(URLQueryItem(name: "o", value: sort.rawValue))
        }
        components.queryItems = items
        return LibraryParser.parseSearch(try await fetchHTML(components.url!))
    }

    public func tags(for model: LibraryModel) async throws -> [LibraryTag] {
        LibraryParser.parseTags(try await fetchHTML(model.pageURL.appending(path: "tags")))
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try OllamaClient.validate(response, data: data)
        guard let html = String(data: data, encoding: .utf8) else { throw OllamaError.unexpectedResponse }
        return html
    }
}

// MARK: - HTML parsing

public enum LibraryParser {
    private static let listItem = regex(#"<li\b[^>]*>(.*?)</li>"#)
    private static let modelLink = regex(#"<a\s+href="/([^"?#]+)""#)
    private static let title = regex(#"<h2[^>]*>\s*<span[^>]*>(.*?)</span>"#)
    private static let summary = regex(#"<p\s+class="max-w-lg[^"]*"[^>]*>(.*?)</p>"#)
    private static let badge = regex(#"<span[^>]*class="[^"]*inline-flex[^"]*"[^>]*>([^<]*)</span>"#)
    private static let pulls = regex(#"<span[^>]*>([^<]*)</span>\s*<span[^>]*>(?:&nbsp;|\s)*Pulls?\s*</span>"#)
    private static let tagCount = regex(#"<span[^>]*>([^<]*)</span>\s*<span[^>]*>(?:&nbsp;|\s)*Tags?\s*</span>"#)
    private static let updated = regex(#"Updated(?:&nbsp;|\s)*</span>\s*<span[^>]*>([^<]*)</span>"#)
    private static let tagBlock = regex(#"<a\s+href="/([^"]+:[^"]+)"\s+class="md:hidden[^"]*"[^>]*>(.*?)</a>"#)
    private static let digest = regex(#"\b([0-9a-f]{12})\b"#, caseInsensitive: false)
    private static let sizeBadge = regex(#"^(?:e?\d+(?:\.\d+)?|\d+x\d+(?:\.\d+)?)[kmbt]$"#)
    private static let htmlTag = regex(#"<[^>]+>"#)

    public static func parseSearch(_ html: String) -> [LibraryModel] {
        var results: [LibraryModel] = []
        var seen = Set<String>()
        for item in matches(listItem, in: html) {
            guard let body = item[1],
                  let path = firstCapture(modelLink, in: body),
                  let rawTitle = firstCapture(title, in: body)
            else { continue }
            let components = path.split(separator: "/")
            guard components.count == 2, !seen.contains(path) else { continue }
            seen.insert(path)

            let badges = matches(badge, in: body).compactMap { $0[1].map(clean) }.filter { !$0.isEmpty }
            let sizes = badges.filter(isSizeBadge)
            let capabilities = badges.filter { !isSizeBadge($0) }.map { $0.lowercased() }
            let name = clean(rawTitle)

            results.append(LibraryModel(
                path: path,
                name: name.isEmpty ? String(components[1]) : name,
                summary: firstCapture(summary, in: body).map(clean) ?? "",
                capabilities: capabilities,
                sizes: sizes,
                pulls: firstCapture(pulls, in: body).map(clean).flatMap(nonEmpty),
                tagCount: firstCapture(tagCount, in: body).map(clean).flatMap(nonEmpty),
                updated: firstCapture(updated, in: body).map(clean).flatMap(nonEmpty)
            ))
        }
        return results
    }

    public static func parseTags(_ html: String) -> [LibraryTag] {
        var results: [LibraryTag] = []
        var seen = Set<String>()
        for match in matches(tagBlock, in: html) {
            guard let path = match[1], let inner = match[2] else { continue }
            let name = path.hasPrefix("library/") ? String(path.dropFirst("library/".count)) : path
            guard !seen.contains(name) else { continue }
            seen.insert(name)

            var text = clean(inner)
            if text.hasPrefix(name) {
                text = String(text.dropFirst(name.count))
            }

            var badges: [String] = []
            var digestValue: String?
            var fieldsText = text
            let nsText = text as NSString
            if let result = digest.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                digestValue = nsText.substring(with: result.range(at: 1))
                badges = nsText.substring(to: result.range.location)
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                fieldsText = nsText.substring(from: result.range.location + result.range.length)
            }
            let fields = fieldsText
                .split(separator: "•")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            results.append(LibraryTag(
                name: name,
                badges: badges,
                digest: digestValue,
                size: fields.first,
                context: fields.first { $0.localizedCaseInsensitiveContains("context") },
                input: fields.first { $0.localizedCaseInsensitiveContains("input") },
                updated: fields.count >= 4 ? fields.last : nil
            ))
        }
        return results
    }

    static func isSizeBadge(_ text: String) -> Bool {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return sizeBadge.firstMatch(in: text, range: range) != nil
    }

    // MARK: Helpers

    private static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        var options: NSRegularExpression.Options = [.dotMatchesLineSeparators]
        if caseInsensitive { options.insert(.caseInsensitive) }
        return try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [[String?]] {
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? nil : nsText.substring(with: range)
            }
        }
    }

    private static func firstCapture(_ regex: NSRegularExpression, in text: String) -> String? {
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1
        else { return nil }
        let range = match.range(at: 1)
        return range.location == NSNotFound ? nil : nsText.substring(with: range)
    }

    private static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    /// Strips tags, decodes entities and collapses whitespace.
    static func clean(_ html: String) -> String {
        let nsHTML = html as NSString
        let withoutTags = htmlTag.stringByReplacingMatches(in: html, range: NSRange(location: 0, length: nsHTML.length), withTemplate: " ")
        return decodeEntities(withoutTags)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "&", let semicolon = text[index...].prefix(10).firstIndex(of: ";") {
                let entity = String(text[text.index(after: index)..<semicolon])
                if let decoded = decode(entity: entity) {
                    result.append(decoded)
                    index = text.index(after: semicolon)
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func decode(entity: String) -> String? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:
            let scalarValue: UInt32?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                scalarValue = UInt32(entity.dropFirst(2), radix: 16)
            } else if entity.hasPrefix("#") {
                scalarValue = UInt32(entity.dropFirst())
            } else {
                scalarValue = nil
            }
            return scalarValue.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}
