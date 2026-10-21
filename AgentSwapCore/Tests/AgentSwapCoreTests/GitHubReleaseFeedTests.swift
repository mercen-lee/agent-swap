import Foundation
import Testing
@testable import AgentSwapCore

@Suite("GitHub 릴리즈 업데이트 피드")
struct GitHubReleaseFeedTests {
    @Test func betaVersionsUseSemanticOrdering() throws {
        let data = try fixture([
            release("v0.1.0-beta.9", prerelease: true),
            release("v0.1.0-beta.10", prerelease: true),
            release("v0.1.0-beta.2", prerelease: true)
        ])
        #expect(try GitHubReleaseFeed.select(from: data, includePrereleases: true)?.tag == "v0.1.0-beta.10")
    }

    @Test func stableInstallsIgnoreBothPrereleaseFlagAndPrereleaseTags() throws {
        let data = try fixture([
            release("v0.1.0"), release("v0.2.0-beta.1"),
            release("v0.3.0", prerelease: true)
        ])
        #expect(try GitHubReleaseFeed.select(from: data, includePrereleases: false)?.tag == "v0.1.0")
        #expect(try GitHubReleaseFeed.select(from: data, includePrereleases: true)?.tag == "v0.3.0")
    }

    @Test func finalVersionSupersedesItsBetas() throws {
        let data = try fixture([release("v1.0.0-beta.999", prerelease: true), release("v1.0.0")])
        #expect(try GitHubReleaseFeed.select(from: data, includePrereleases: true)?.tag == "v1.0.0")
    }

    @Test(arguments: ["draft", "unpublished", "missingFeed", "missingArchive", "uploading", "emptyFeed", "hugeFeed", "foreignFeed", "foreignArchive"])
    func skipsIncompleteOrForeignReleases(reason: String) throws {
        var invalid = release("v2.0.0")
        var assets = try #require(invalid["assets"] as? [[String: Any]])
        switch reason {
        case "draft": invalid["draft"] = true
        case "unpublished": invalid["published_at"] = NSNull()
        case "missingFeed": assets.removeFirst()
        case "missingArchive": assets.removeLast()
        case "uploading": assets[0]["state"] = "new"
        case "emptyFeed": assets[0]["size"] = 0
        case "hugeFeed": assets[0]["size"] = 1_048_577
        case "foreignFeed": assets[0]["browser_download_url"] = "https://github.com/other/repo/releases/download/v2.0.0/appcast.xml"
        case "foreignArchive": assets[1]["browser_download_url"] = "https://example.invalid/update.zip"
        default: Issue.record("Unknown fixture")
        }
        invalid["assets"] = assets
        let data = try fixture([invalid, release("v1.0.0")])
        #expect(try GitHubReleaseFeed.select(from: data, includePrereleases: true)?.tag == "v1.0.0")
    }

    @Test(arguments: ["1.0.0", "v01.0.0", "v1.0.0-beta.01", "v1.0.0-", "v1.0.0-a..b", "v1.0.0+metadata", "v1.0.0/../other", "v1.0.0-한글"])
    func rejectsInvalidOrPathLikeTags(tag: String) {
        #expect(GitHubReleaseFeed.url(for: tag) == nil)
        #expect(!GitHubReleaseFeed.includesPrereleases(installedTag: tag))
    }

    @Test func prereleasesAreAnInstalledChannelChoice() {
        #expect(GitHubReleaseFeed.includesPrereleases(installedTag: "v0.1.0-beta.6"))
        #expect(!GitHubReleaseFeed.includesPrereleases(installedTag: "v1.0.0"))
        #expect(!GitHubReleaseFeed.includesPrereleases(installedTag: nil))
    }

    @Test func oversizedAndMalformedMetadataIsNotTreatedAsNoUpdates() {
        #expect(throws: GitHubReleaseFeedError.responseTooLarge) {
            try GitHubReleaseFeed.select(from: Data(repeating: 32, count: GitHubReleaseFeed.maximumResponseSize + 1), includePrereleases: true)
        }
        #expect(throws: (any Error).self) {
            try GitHubReleaseFeed.select(from: Data("{\"message\":\"rate limited\"}".utf8), includePrereleases: true)
        }
    }

    @Test func noEligibleReleaseHasNoFeed() throws {
        #expect(try GitHubReleaseFeed.select(from: fixture([]), includePrereleases: true) == nil)
    }

    @Test func arbitrarilyLongNumericPrereleaseOrderingDoesNotOverflow() throws {
        let smaller = "v1.0.0-beta.999999999999999999999999999999"
        let larger = "v1.0.0-beta.1000000000000000000000000000000"
        let data = try fixture([release(smaller, prerelease: true), release(larger, prerelease: true)])
        #expect(try GitHubReleaseFeed.select(from: data, includePrereleases: true)?.tag == larger)
    }

    private func fixture(_ releases: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: releases)
    }

    private func release(_ tag: String, prerelease: Bool = false) -> [String: Any] {
        let prefix = "https://github.com/mercen-lee/agent-swap/releases/download/\(tag)/"
        let archive = "AgentSwap-\(tag.dropFirst())-universal.zip"
        return [
            "tag_name": tag, "draft": false, "prerelease": prerelease,
            "published_at": "2026-10-21T00:00:00Z",
            "assets": [
                ["name": "appcast.xml", "state": "uploaded", "size": 1_024, "browser_download_url": prefix + "appcast.xml"],
                ["name": archive, "state": "uploaded", "size": 10_000_000, "browser_download_url": prefix + archive]
            ]
        ]
    }
}
