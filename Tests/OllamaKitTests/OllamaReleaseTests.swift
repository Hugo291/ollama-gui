import Foundation
import Testing
@testable import OllamaKit

@Suite("Ollama releases")
struct OllamaReleaseTests {
    @Test func decodesDownloadSizeWithAndWithoutMetadata() throws {
        let json = """
        [
          {"name":"Ollama-darwin.zip","browser_download_url":"https://example.com/Ollama-darwin.zip","size":2147483648},
          {"name":"sha256sum.txt","browser_download_url":"https://example.com/sha256sum.txt"}
        ]
        """
        let assets = try JSONDecoder().decode([OllamaRelease.Asset].self, from: Data(json.utf8))
        #expect(assets[0].size == 2_147_483_648)
        #expect(assets[1].size == nil)
    }

    @Test(arguments: [
        ("0.35.1", "0.35.0", false),
        ("0.40.0-rc0", "0.35.1", false),
        ("0.40.0-rc2", "0.40.0-rc1", false),
        ("0.40.0", "0.40.0-rc2", false),
        ("v1.2", "1.2.0", true),
    ])
    func comparesVersions(left: String, right: String, equal: Bool) throws {
        let lhs = try #require(OllamaVersion(left))
        let rhs = try #require(OllamaVersion(right))
        if equal {
            #expect(lhs == rhs)
        } else {
            #expect(lhs > rhs)
        }
    }

    @Test func stableInstallationsIgnorePrereleases() throws {
        let assets = Self.macAssets()
        let releases = [
            OllamaRelease(tagName: "v0.40.0-rc0", isPrerelease: true, assets: assets),
            OllamaRelease(tagName: "v0.36.0", assets: assets),
            OllamaRelease(tagName: "v0.35.2", assets: assets),
        ]
        #expect(OllamaReleaseClient.latestUpdate(for: "0.35.1", in: releases)?.version == "0.36.0")
    }

    @Test func prereleaseInstallationsFollowPrereleases() throws {
        let assets = Self.macAssets()
        let releases = [
            OllamaRelease(tagName: "v0.40.0-rc2", isPrerelease: true, assets: assets),
            OllamaRelease(tagName: "v0.40.0-rc1", isPrerelease: true, assets: assets),
            OllamaRelease(tagName: "v0.35.2", assets: assets),
        ]
        #expect(OllamaReleaseClient.latestUpdate(for: "0.40.0-rc0", in: releases)?.version == "0.40.0-rc2")
    }

    @Test func returnsNilWhenCurrentVersionIsNewest() {
        let releases = [
            OllamaRelease(tagName: "v0.35.1", assets: Self.macAssets()),
            OllamaRelease(tagName: "v0.35.0", assets: Self.macAssets()),
        ]
        #expect(OllamaReleaseClient.latestUpdate(for: "0.35.1", in: releases) == nil)
    }

    @Test func versionPickerIncludesNewerStableAndPreviewReleases() {
        let assets = Self.macAssets()
        let releases = [
            OllamaRelease(tagName: "v0.40.0-rc0", isPrerelease: true, assets: assets),
            OllamaRelease(tagName: "v0.36.0", assets: assets),
            OllamaRelease(tagName: "v0.35.1", assets: assets),
        ]
        let updates = OllamaReleaseClient.availableUpdates(for: "0.35.1", in: releases)
        #expect(updates.map(\.version) == ["0.40.0-rc0", "0.36.0"])
    }

    @Test func versionPickerIncludesOlderVersionsAndExcludesUninstallableReleases() {
        let assets = Self.macAssets()
        let releases = [
            OllamaRelease(tagName: "v0.35.0", assets: assets),
            OllamaRelease(tagName: "v0.40.0-rc0", isPrerelease: true, assets: assets),
            OllamaRelease(tagName: "v0.35.1", assets: assets),
            OllamaRelease(tagName: "v0.36.0", assets: assets),
            OllamaRelease(tagName: "v0.50.0", isDraft: true, assets: assets),
            OllamaRelease(tagName: "v0.49.0", assets: [assets[0]]),
        ]
        #expect(OllamaReleaseClient.availableVersions(in: releases).map(\.version)
                == ["0.40.0-rc0", "0.36.0", "0.35.1", "0.35.0"])
        #expect(OllamaReleaseClient.availableVersions(in: releases, includePrereleases: false).map(\.version)
                == ["0.36.0", "0.35.1", "0.35.0"])
    }

    private static func macAssets() -> [OllamaRelease.Asset] {
        [
            .init(name: "Ollama-darwin.zip", downloadURL: URL(string: "https://example.com/Ollama-darwin.zip")!),
            .init(name: "sha256sum.txt", downloadURL: URL(string: "https://example.com/sha256sum.txt")!),
        ]
    }
}
