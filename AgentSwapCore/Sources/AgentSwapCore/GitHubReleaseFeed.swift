import Foundation

/// Selects public update metadata. Sparkle independently verifies the signed feed and archive.
public struct GitHubReleaseFeed: Equatable, Sendable {
    public let tag: String
    public let url: URL

    public static let repository = "mercen-lee/agent-swap"
    public static let releasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
    public static let maximumResponseSize = 4 * 1_024 * 1_024

    public static func includesPrereleases(installedTag: String?) -> Bool {
        guard let installedTag, let version = ReleaseVersion(tag: installedTag) else { return false }
        return !version.prerelease.isEmpty
    }

    public static func url(for tag: String) -> URL? {
        guard ReleaseVersion(tag: tag) != nil else { return nil }
        return URL(string: "https://github.com/\(repository)/releases/download/\(tag)/appcast.xml")
    }

    public static func select(from data: Data, includePrereleases: Bool) throws -> GitHubReleaseFeed? {
        guard data.count <= maximumResponseSize else { throw GitHubReleaseFeedError.responseTooLarge }
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> (ReleaseVersion, GitHubReleaseFeed)? in
            guard !release.draft, release.publishedAt != nil,
                  let version = ReleaseVersion(tag: release.tag),
                  includePrereleases || (!release.prerelease && version.prerelease.isEmpty),
                  let feedURL = url(for: release.tag) else { return nil }
            let archiveName = "AgentSwap-\(release.tag.dropFirst())-universal.zip"
            let archiveURL = "https://github.com/\(repository)/releases/download/\(release.tag)/\(archiveName)"
            guard release.assets.contains(where: {
                $0.name == "appcast.xml" && $0.state == "uploaded" && $0.size > 0 &&
                    $0.size <= 1_048_576 && $0.downloadURL == feedURL.absoluteString
            }), release.assets.contains(where: {
                $0.name == archiveName && $0.state == "uploaded" && $0.size > 0 &&
                    $0.downloadURL == archiveURL
            }) else { return nil }
            return (version, GitHubReleaseFeed(tag: release.tag, url: feedURL))
        }.max { $0.0 < $1.0 }?.1
    }

    private struct Release: Decodable {
        let tag: String
        let draft: Bool
        let prerelease: Bool
        let publishedAt: String?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name", draft, prerelease, publishedAt = "published_at", assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
        let size: Int
        let downloadURL: String

        enum CodingKeys: String, CodingKey {
            case name, state, size, downloadURL = "browser_download_url"
        }
    }
}

public enum GitHubReleaseFeedError: Error, Sendable {
    case responseTooLarge
}

/// Release tags use the same bounded SemVer format as package-release.sh.
struct ReleaseVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init?(tag: String) {
        guard tag.first == "v", tag.utf8.count <= 193 else { return nil }
        let parts = tag.dropFirst().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3,
              numbers.allSatisfy({ Self.isNumber(String($0)) }),
              let major = Int(numbers[0]), let minor = Int(numbers[1]), let patch = Int(numbers[2]) else { return nil }
        let prerelease = parts.count == 2 ? parts[1].split(separator: ".", omittingEmptySubsequences: false).map(String.init) : []
        guard prerelease.allSatisfy({ identifier in
            !identifier.isEmpty && identifier.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
            } && (!identifier.utf8.allSatisfy { (48...57).contains($0) } || Self.isNumber(identifier))
        }) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    private static func isNumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && (value == "0" || value.first != "0")
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.utf8.allSatisfy { (48...57).contains($0) }
            let rightNumeric = right.utf8.allSatisfy { (48...57).contains($0) }
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
