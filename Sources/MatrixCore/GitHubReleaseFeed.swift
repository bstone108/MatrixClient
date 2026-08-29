import Foundation

public struct GitHubReleaseAsset: Hashable, Sendable {
    public let name: String
    public let downloadURL: URL

    public init(name: String, downloadURL: URL) {
        self.name = name
        self.downloadURL = downloadURL
    }
}

public struct GitHubReleaseSummary: Hashable, Sendable {
    public let tagName: String
    public let version: DateBuildVersion
    public let assets: [GitHubReleaseAsset]

    public init(tagName: String, version: DateBuildVersion, assets: [GitHubReleaseAsset]) {
        self.tagName = tagName
        self.version = version
        self.assets = assets
    }

    public func macOSDiskImage(architecture: String) -> GitHubReleaseAsset? {
        let arch = architecture.lowercased()
        // Dedicated per-arch assets only. Do not fall back to a universal filename.
        let suffix = "-macos-\(arch).dmg"
        return assets.first { asset in
            let name = asset.name.lowercased()
            return name.hasPrefix("matrixclient-") && name.hasSuffix(suffix)
        }
    }
}

public enum GitHubReleaseFeed {
    public static let repositoryPath = "bstone108/MatrixClient"
    public static let releasesURL = URL(string: "https://api.github.com/repos/bstone108/MatrixClient/releases")!

    public static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// Stable GitHub Releases URL for the latest per-arch Sparkle appcast.
    public static func appcastURL(architecture: String) -> URL? {
        let arch = architecture.lowercased()
        guard arch == "arm64" || arch == "x86_64" else { return nil }
        return URL(string: "https://github.com/\(repositoryPath)/releases/latest/download/appcast-\(arch).xml")
    }

    public static func diskImageDownloadURL(version: DateBuildVersion, architecture: String) -> URL? {
        let arch = architecture.lowercased()
        guard arch == "arm64" || arch == "x86_64" else { return nil }
        let name = "MatrixClient-\(version.rawValue)-macos-\(arch).dmg"
        return URL(string: "https://github.com/\(repositoryPath)/releases/download/v\(version.rawValue)/\(name)")
    }

    public static func parseReleases(from data: Data) throws -> [GitHubReleaseSummary] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode([DTO].self, from: data)
        return decoded.compactMap { item in
            guard !item.draft, !item.prerelease,
                  let version = DateBuildVersion.parse(item.tagName) else {
                return nil
            }
            let assets = item.assets.compactMap { asset -> GitHubReleaseAsset? in
                guard let url = URL(string: asset.browserDownloadUrl) else { return nil }
                return GitHubReleaseAsset(name: asset.name, downloadURL: url)
            }
            return GitHubReleaseSummary(tagName: item.tagName, version: version, assets: assets)
        }
    }

    public static func newestRelease(
        in releases: [GitHubReleaseSummary],
        newerThan current: DateBuildVersion?,
        architecture: String
    ) -> (GitHubReleaseSummary, GitHubReleaseAsset)? {
        let candidates = releases
            .compactMap { release -> (GitHubReleaseSummary, GitHubReleaseAsset)? in
                guard let asset = release.macOSDiskImage(architecture: architecture) else { return nil }
                if let current, release.version <= current { return nil }
                return (release, asset)
            }
            .sorted { lhs, rhs in lhs.0.version > rhs.0.version }
        return candidates.first
    }

    private struct DTO: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [AssetDTO]
    }

    private struct AssetDTO: Decodable {
        let name: String
        let browserDownloadUrl: String
    }
}
