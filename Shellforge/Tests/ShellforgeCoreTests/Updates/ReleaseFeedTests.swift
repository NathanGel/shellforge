// Ported from AiTerm (app/Tests/AiTermCoreTests/ReleaseFeedTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// GitHub only: AiTerm's GitLab feed and its token are not ported.
@Suite struct ReleaseFeedTests {
    @Test func parsesAGitHubFeed() {
        #expect(ReleaseFeed("github:octocat/hello") == .gitHub(owner: "octocat", repo: "hello"))
        #expect(ReleaseFeed("github:octo-cat/hello.world.git") == .gitHub(owner: "octo-cat", repo: "hello.world"))
    }

    /// A typo in the shipped feed would silently stop updates for everyone. The app's Info.plist is
    /// iTerm2's `plists/dev-iTerm2.plist`, which the build copies to `plists/iTerm2.plist`.
    @Test func theShippedFeedIsShellforgesGitHubRepository() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plists/dev-iTerm2.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        let feed = try #require(info["ShellforgeUpdateFeed"] as? String)
        #expect(ReleaseFeed(feed) == .gitHub(owner: "NathanGel", repo: "shellforge"))
        // Sparkle has no feed of iTerm2's to read, and never checks on its own.
        #expect(info.allKeys.compactMap { $0 as? String }.filter { $0.hasPrefix("SUFeedURL") }.isEmpty)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
    }

    /// The update check is anonymous: a GitHub source has no token to send.
    @Test func aGitHubSourceIsTheFeedsRepository() throws {
        let source = try #require(ReleaseFeed("github:octocat/hello")!.source() as? GitHubReleaseSource)
        #expect(source.owner == "octocat" && source.repo == "hello")
    }

    /// AiTerm's other feed kind is not one here.
    @Test func rejectsWhatItCannotUse() {
        for bad in ["", "github:", "github:owner", "github:owner/", "github:/repo", "github:a/b/c", "github:own er/repo",
                    "github:https://github.com/a/b", "gitlab:https://git.example.net/ai/aiterm", "https://github.com/a/b"] {
            #expect(ReleaseFeed(bad) == nil, "\(bad)")
        }
    }

    @Test func missingFeedIsNoFeed() {
        #expect(throws: UpdateError.noFeed) { _ = try ReleaseFeed.source(for: nil) }
        #expect(throws: UpdateError.noFeed) { _ = try ReleaseFeed.source(for: "nonsense") }
    }
}
