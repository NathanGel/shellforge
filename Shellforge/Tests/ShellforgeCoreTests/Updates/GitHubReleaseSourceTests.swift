// Ported from AiTerm (app/Tests/AiTermCoreTests/GitHubReleaseSourceTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct GitHubReleaseSourceTests {
    let listURL = "https://api.github.com/repos/octocat/hello/releases?per_page=20"

    func release(_ tag: String, asset: Bool = true, draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets: [[String: Any]] = asset
            ? [["name": "Shellforge-\(version).dmg", "browser_download_url": "https://github.com/octocat/hello/releases/download/\(tag)/Shellforge-\(version).dmg"]]
            : []
        return ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": assets]
    }

    func page(_ entries: [[String: Any]]) -> Data { try! JSONSerialization.data(withJSONObject: entries) }

    func source(_ handler: @escaping StubURLProtocol.Handler) -> (GitHubReleaseSource, StubSession) {
        let stub = StubSession(handler: handler)
        return (GitHubReleaseSource(owner: "octocat", repo: "hello", session: stub.session), stub)
    }

    @Test func latestReadsTheReleaseListAnonymously() async throws {
        let (src, stub) = source { _ in (200, self.page([self.release("v0.3.0")])) }
        let release = try await src.latest()
        #expect(release == Release(version: ReleaseVersion("0.3.0")!,
                                   assetURL: URL(string: "https://github.com/octocat/hello/releases/download/v0.3.0/Shellforge-0.3.0.dmg")!))
        let req = try #require(stub.lastRequest)
        #expect(req.url?.absoluteString == listURL)
        #expect(req.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(req.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
    }

    /// iTerm2's own image would never be taken for Shellforge's.
    @Test func onlyShellforgesImageCounts() async {
        let entry: [String: Any] = ["tag_name": "v0.3.0", "assets": [["name": "iTerm2-0.3.0.dmg", "browser_download_url": "https://x/iTerm2-0.3.0.dmg"],
                                                                        ["name": "AiTerm-0.3.0.dmg", "browser_download_url": "https://x/AiTerm-0.3.0.dmg"]]]
        let list = page([entry])
        await #expect(throws: UpdateError.missingAsset(.gitHub, "0.3.0")) {
            _ = try await self.source { _ in (200, list) }.0.latest()
        }
    }

    @Test func draftsAndPrereleasesAreNeverOffered() async throws {
        let list = page([release("v0.6.0", draft: true), release("v0.5.0", prerelease: true), release("v0.4.0")])
        let (src, _) = source { _ in (200, list) }
        #expect(try await src.latest().version == ReleaseVersion("0.4.0")!)
    }

    @Test func aPageOfOnlyDraftsIsNoRelease() async {
        await #expect(throws: UpdateError.noRelease(.gitHub)) {
            _ = try await self.source { _ in (200, self.page([self.release("v0.6.0", draft: true)])) }.0.latest()
        }
    }

    @Test func strayTagsAndMissingImagesAreSkipped() async throws {
        let list = page([release("nightly"), release("v0.5.0", asset: false), release("v0.4.0")])
        let (src, _) = source { _ in (200, list) }
        #expect(try await src.latest().version == ReleaseVersion("0.4.0")!)
        await #expect(throws: UpdateError.missingAsset(.gitHub, "0.5.0")) {
            _ = try await self.source { _ in (200, self.page([self.release("v0.5.0", asset: false)])) }.0.latest()
        }
        await #expect(throws: UpdateError.unreadableTag(.gitHub, "nightly")) {
            _ = try await self.source { _ in (200, self.page([self.release("nightly")])) }.0.latest()
        }
    }

    @Test func emptyAndGarbagePages() async {
        await #expect(throws: UpdateError.noRelease(.gitHub)) { _ = try await self.source { _ in (200, Data("[]".utf8)) }.0.latest() }
        await #expect(throws: UpdateError.badResponse(.gitHub, 200)) { _ = try await self.source { _ in (200, Data("<html>".utf8)) }.0.latest() }
    }

    @Test func statusCodesMapToErrors() async {
        for (status, error) in [(404, UpdateError.projectNotFound(.gitHub, "octocat/hello")), (403, .rateLimited),
                                (429, .rateLimited), (500, .badResponse(.gitHub, 500))] {
            await #expect(throws: error) { _ = try await self.source { _ in (status, Data()) }.0.latest() }
        }
    }

    @Test func downloadWritesTheImageWithNoCredential() async throws {
        let dir = TestScratch.root.appendingPathComponent("release-download-\(UUID().uuidString)")
        let (src, stub) = source { _ in (200, Data("dmg-bytes".utf8)) }
        let asset = URL(string: "https://github.com/octocat/hello/releases/download/v0.3.0/Shellforge-0.3.0.dmg")!
        let destination = dir.appendingPathComponent("Shellforge-0.3.0.dmg")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("an earlier attempt".utf8).write(to: destination)
        try await src.download(Release(version: ReleaseVersion("0.3.0")!, assetURL: asset), to: destination)
        #expect(try Data(contentsOf: destination) == Data("dmg-bytes".utf8))
        #expect(stub.lastRequest?.url == asset)
        #expect(stub.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func aMissingImageIsABadResponseNotAMissingRepository() async {
        await #expect(throws: UpdateError.badResponse(.gitHub, 404)) {
            let release = Release(version: ReleaseVersion("0.3.0")!, assetURL: URL(string: "https://github.com/x/Shellforge-0.3.0.dmg")!)
            try await self.source { _ in (404, Data()) }.0.download(release, to: TestScratch.root.appendingPathComponent(UUID().uuidString))
        }
    }
}
