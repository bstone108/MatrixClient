import Foundation
import MatrixCore
import Testing

@Test
func githubReleaseFeedIgnoresDraftsPrereleasesAndPicksNewestDmg() throws {
    let json = """
    [
      {
        "tag_name": "v2026.8.24.1",
        "draft": false,
        "prerelease": true,
        "assets": [
          {"name": "MatrixClient-2026.8.24.1-macos-arm64.dmg", "browser_download_url": "https://example.test/old.dmg"}
        ]
      },
      {
        "tag_name": "v2026.8.25.2",
        "draft": false,
        "prerelease": false,
        "assets": [
          {"name": "MatrixClient-2026.8.25.2-macos-arm64.dmg", "browser_download_url": "https://example.test/new.dmg"},
          {"name": "MatrixClient-2026.8.25.2-macos-arm64.zip", "browser_download_url": "https://example.test/new.zip"}
        ]
      },
      {
        "tag_name": "v2026.8.25.1",
        "draft": false,
        "prerelease": false,
        "assets": [
          {"name": "MatrixClient-2026.8.25.1-macos-arm64.dmg", "browser_download_url": "https://example.test/mid.dmg"}
        ]
      },
      {
        "tag_name": "v2026.8.26.1",
        "draft": true,
        "prerelease": false,
        "assets": [
          {"name": "MatrixClient-2026.8.26.1-macos-arm64.dmg", "browser_download_url": "https://example.test/draft.dmg"}
        ]
      }
    ]
    """.data(using: .utf8)!

    let releases = try GitHubReleaseFeed.parseReleases(from: json)
    #expect(releases.map(\.version.rawValue) == ["2026.8.25.2", "2026.8.25.1"])

    let current = DateBuildVersion.parse("2026.8.24.9")
    let newest = GitHubReleaseFeed.newestRelease(in: releases, newerThan: current, architecture: "arm64")
    #expect(newest?.0.version.rawValue == "2026.8.25.2")
    #expect(newest?.1.name == "MatrixClient-2026.8.25.2-macos-arm64.dmg")
}

@Test
func githubReleaseFeedDoesNotOfferCurrentOrOlderBuilds() throws {
    let json = """
    [
      {
        "tag_name": "v2026.8.25.2",
        "draft": false,
        "prerelease": false,
        "assets": [
          {"name": "MatrixClient-2026.8.25.2-macos-arm64.dmg", "browser_download_url": "https://example.test/new.dmg"}
        ]
      }
    ]
    """.data(using: .utf8)!
    let releases = try GitHubReleaseFeed.parseReleases(from: json)
    let current = DateBuildVersion.parse("2026.8.25.2")
    #expect(GitHubReleaseFeed.newestRelease(in: releases, newerThan: current, architecture: "arm64") == nil)
    #expect(GitHubReleaseFeed.newestRelease(in: releases, newerThan: current, architecture: "x86_64") == nil)
}

@Test
func githubReleaseFeedPrefersUniversalDmgForAppleSiliconAndIntel() throws {
    let json = """
    [
      {
        "tag_name": "v2026.8.27.1",
        "draft": false,
        "prerelease": false,
        "assets": [
          {"name": "MatrixClient-2026.8.27.1-macos-universal.dmg", "browser_download_url": "https://example.test/universal.dmg"},
          {"name": "MatrixClient-2026.8.27.1-macos-universal.zip", "browser_download_url": "https://example.test/universal.zip"},
          {"name": "MatrixClient-2026.8.27.1-macos-arm64.dmg", "browser_download_url": "https://example.test/legacy-arm.dmg"}
        ]
      }
    ]
    """.data(using: .utf8)!
    let releases = try GitHubReleaseFeed.parseReleases(from: json)
    let current = DateBuildVersion.parse("2026.8.25.2")
    let appleSilicon = GitHubReleaseFeed.newestRelease(in: releases, newerThan: current, architecture: "arm64")
    let intel = GitHubReleaseFeed.newestRelease(in: releases, newerThan: current, architecture: "x86_64")
    #expect(appleSilicon?.1.name == "MatrixClient-2026.8.27.1-macos-universal.dmg")
    #expect(intel?.1.name == "MatrixClient-2026.8.27.1-macos-universal.dmg")
}

@Test
func githubReleaseFeedDoesNotGiveIntelAnAppleSiliconOnlyDmg() throws {
    let json = """
    [
      {
        "tag_name": "v2026.8.25.2",
        "draft": false,
        "prerelease": false,
        "assets": [
          {"name": "MatrixClient-2026.8.25.2-macos-arm64.dmg", "browser_download_url": "https://example.test/arm.dmg"}
        ]
      }
    ]
    """.data(using: .utf8)!
    let releases = try GitHubReleaseFeed.parseReleases(from: json)
    let current = DateBuildVersion.parse("2026.8.24.1")
    #expect(GitHubReleaseFeed.newestRelease(in: releases, newerThan: current, architecture: "arm64")?.1.name == "MatrixClient-2026.8.25.2-macos-arm64.dmg")
    #expect(GitHubReleaseFeed.newestRelease(in: releases, newerThan: current, architecture: "x86_64") == nil)
}
