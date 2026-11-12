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
}
