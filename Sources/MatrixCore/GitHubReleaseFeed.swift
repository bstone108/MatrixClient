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
        let suffixes = [
            "-macos-universal.dmg",
            "-macos-arm64_x86_64.dmg",
            "-macos-\(arch).dmg",
        ]
        for suffix in suffixes {
            if let asset = assets.first(where: { asset in
                let name = asset.name.lowercased()
                return name.hasPrefix("matrixclient-") && name.hasSuffix(suffix)
            }) {
                return asset
            }
        }
        return nil
    }
}

public enum GitHubReleaseFeed {
    public static let repositoryPath = "bstone108/MatrixClient"
    public static let releasesURL = URL(string: "https://api.github.com/repos/bstone108/MatrixClient/releases")!

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
