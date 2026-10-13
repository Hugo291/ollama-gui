import Foundation

/// A version published on GitHub: Ollama, or Ollama GUI itself.
public struct OllamaRelease: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let downloadURL: URL
        public let size: Int64?

        enum CodingKeys: String, CodingKey {
            case name
            case size
            case downloadURL = "browser_download_url"
        }

        public init(name: String, downloadURL: URL, size: Int64? = nil) {
            self.name = name
            self.downloadURL = downloadURL
            self.size = size
        }
    }

    public let tagName: String
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [Asset]
    /// The release notes, in Markdown.
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case isDraft = "draft"
        case isPrerelease = "prerelease"
        case assets
        case notes = "body"
    }

    public init(tagName: String, isDraft: Bool = false, isPrerelease: Bool = false, assets: [Asset] = [], notes: String? = nil) {
        self.tagName = tagName
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.assets = assets
        self.notes = notes
    }

    public var version: String { tagName.trimmingPrefix("v") }

    public func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }
}

/// Reads Ollama's official GitHub releases and selects the appropriate update channel.
/// Also finds the updates of Ollama GUI itself.
public struct OllamaReleaseClient: Sendable {
    /// The archive attached to every Ollama GUI release.
    public static let appArchiveName = "OllamaGUI-macOS.zip"

    private let session: URLSession
    private let releasesURL = URL(string: "https://api.github.com/repos/ollama/ollama/releases?per_page=100")!
    private let appReleaseURL = URL(string: "https://api.github.com/repos/Hugo291/ollama-gui/releases/latest")!

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func latestUpdate(for currentVersion: String) async throws -> OllamaRelease? {
        try await availableUpdates(for: currentVersion, includePrereleases: OllamaVersion(currentVersion)?.isPrerelease == true).first
    }

    /// Returns every newer macOS release, newest first. The UI includes pre-releases
    /// so the user can explicitly opt into a preview version.
    public func availableUpdates(for currentVersion: String, includePrereleases: Bool = true) async throws -> [OllamaRelease] {
        let releases = try await availableVersions(includePrereleases: includePrereleases)
        return Self.availableUpdates(for: currentVersion, in: releases, includePrereleases: includePrereleases)
    }

    /// Recent installable macOS releases, including older versions and previews.
    public func availableVersions(includePrereleases: Bool = true) async throws -> [OllamaRelease] {
        let releases: [OllamaRelease] = try await fetch(releasesURL)
        return Self.availableVersions(in: releases, includePrereleases: includePrereleases)
    }

    /// The latest stable release of Ollama GUI, when it is newer than `currentVersion`.
    public func appUpdate(for currentVersion: String) async throws -> OllamaRelease? {
        Self.appUpdate(for: currentVersion, in: try await fetch(appReleaseURL))
    }

    static func appUpdate(for currentVersion: String, in release: OllamaRelease) -> OllamaRelease? {
        guard let current = OllamaVersion(currentVersion), let latest = OllamaVersion(release.version),
              latest > current, release.asset(named: appArchiveName) != nil else { return nil }
        return release
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ollama-gui", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try OllamaClient.validate(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Stable installations stay on stable releases. Pre-release installations keep
    /// following pre-releases, so an RC never appears to be older than the stable channel.
    static func latestUpdate(for currentVersion: String, in releases: [OllamaRelease]) -> OllamaRelease? {
        guard let current = OllamaVersion(currentVersion) else { return nil }
        return availableUpdates(for: currentVersion, in: releases, includePrereleases: current.isPrerelease).first
    }

    static func availableUpdates(
        for currentVersion: String,
        in releases: [OllamaRelease],
        includePrereleases: Bool = true
    ) -> [OllamaRelease] {
        guard let current = OllamaVersion(currentVersion) else { return [] }
        return availableVersions(in: releases, includePrereleases: includePrereleases)
            .filter { OllamaVersion($0.version).map { $0 > current } ?? false }
    }

    static func availableVersions(in releases: [OllamaRelease], includePrereleases: Bool = true) -> [OllamaRelease] {
        return releases
            .filter {
                !$0.isDraft
                    && (includePrereleases || !$0.isPrerelease)
                    && $0.asset(named: "Ollama-darwin.zip") != nil
                    && $0.asset(named: "sha256sum.txt") != nil
            }
            .compactMap { release -> (OllamaRelease, OllamaVersion)? in
                guard let version = OllamaVersion(release.version) else { return nil }
                return (release, version)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

/// SemVer-like comparison for Ollama tags such as `0.35.1` and `0.40.0-rc2`.
struct OllamaVersion: Comparable, Equatable {
    let numbers: [Int]
    let prerelease: [Part]?

    enum Part: Equatable {
        case number(Int)
        case text(String)
    }

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).trimmingPrefix("v")
        let pieces = value.split(separator: "-", maxSplits: 1).map(String.init)
        let parsedNumbers = pieces[0].split(separator: ".").compactMap { Int($0) }
        guard parsedNumbers.count == pieces[0].split(separator: ".").count, !parsedNumbers.isEmpty else { return nil }
        numbers = parsedNumbers
        prerelease = pieces.count == 2 ? Self.parts(of: pieces[1]) : nil
    }

    var isPrerelease: Bool { prerelease != nil }

    static func == (lhs: Self, rhs: Self) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.numbers.count, rhs.numbers.count)
        for index in 0..<count {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some(let left), .some(let right)):
            for index in 0..<min(left.count, right.count) {
                if left[index] == right[index] { continue }
                switch (left[index], right[index]) {
                case (.number(let a), .number(let b)): return a < b
                case (.text(let a), .text(let b)): return a.localizedStandardCompare(b) == .orderedAscending
                case (.number, .text): return true
                case (.text, .number): return false
                }
            }
            return left.count < right.count
        }
    }

    private static func parts(of value: String) -> [Part] {
        var result: [Part] = []
        var current = ""
        var currentIsNumber: Bool?
        func appendCurrent() {
            guard !current.isEmpty else { return }
            result.append(Int(current).map(Part.number) ?? .text(current.lowercased()))
            current = ""
        }
        for character in value {
            guard character.isLetter || character.isNumber else {
                appendCurrent()
                currentIsNumber = nil
                continue
            }
            let isNumber = character.isNumber
            if let currentIsNumber, currentIsNumber != isNumber { appendCurrent() }
            current.append(character)
            currentIsNumber = isNumber
        }
        appendCurrent()
        return result
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}
