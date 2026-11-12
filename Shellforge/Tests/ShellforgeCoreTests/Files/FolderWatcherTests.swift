import XCTest
@testable import ShellforgeCore

final class FolderWatcherTests: XCTestCase {
    private let root = "/work/acme-web"

    private func relevant(_ path: String) -> Bool { FolderWatcher.isRelevant(root + path, root: root) }

    func testOrdinaryFilesCount() {
        XCTAssertTrue(relevant("/src/app.ts"))
        XCTAssertTrue(relevant("/README.md"))
        XCTAssertTrue(relevant(""))
    }

    func testGitNoiseDoesNotCount() {
        XCTAssertFalse(relevant("/.git/index.lock"))
        XCTAssertFalse(relevant("/.git/objects/ab/cdef"))
        XCTAssertFalse(relevant("/.git/logs/HEAD"))
        XCTAssertFalse(relevant("/.git"))
        XCTAssertFalse(relevant("/packages/lib/.git/index"))
    }

    func testTheFilesThatDecideWhatIsListedCount() {
        XCTAssertTrue(relevant("/.git/index"))
        XCTAssertTrue(relevant("/.git/HEAD"))
        XCTAssertTrue(relevant("/.git/info/exclude"))
        XCTAssertFalse(relevant("/.git/info/refs"))
    }

    func testTaskWorktreesDoNotCount() {
        XCTAssertFalse(relevant("/.worktrees/fix-login/src/app.ts"))
        XCTAssertTrue(relevant("/src/.worktrees-notes.md"))
    }

    func testAPathOutsideTheRootIsPassedOn() {
        XCTAssertTrue(FolderWatcher.isRelevant("/elsewhere/file.txt", root: root))
        XCTAssertFalse(FolderWatcher.isRelevant(root + "/.git/HEAD2", root: root + "/"))
    }

    /// A folder under the temporary directory (`/var/folders/...`), which the stream reports
    /// under `/private/var/folders/...`.
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git/objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        return folder
    }

    func testTheRootIsWhereTheStreamReportsIt() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = FolderWatcher.resolvedRoot(folder.path)
        XCTAssertTrue(root.hasPrefix("/private/"), root)
        XCTAssertFalse(FolderWatcher.isRelevant(root + "/.git/objects/x", root: root), "git noise counted under /private")
        XCTAssertTrue(FolderWatcher.isRelevant(root + "/src/app.ts", root: root))
    }

    func testAFileChangeIsReported() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let changed = expectation(description: "a change under src")
        changed.assertForOverFulfill = false
        let watcher = FolderWatcher()
        watcher.watch(folder.path) { changed.fulfill() }
        defer { watcher.stop() }
        try "x".write(to: folder.appendingPathComponent("src/app.ts"), atomically: true, encoding: .utf8)
        wait(for: [changed], timeout: 30)
    }
}
