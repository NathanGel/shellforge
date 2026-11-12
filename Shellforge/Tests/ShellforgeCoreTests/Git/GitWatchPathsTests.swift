import XCTest
@testable import ShellforgeCore

final class GitWatchPathsTests: XCTestCase {
    private let root = "/work/acme-web"

    private func relevant(_ path: String) -> Bool { GitWatchPaths.isRelevant(root + path, root: root) }

    func testRefsChangesAreRelevantObjectsAreNot() {
        XCTAssertTrue(relevant("/.git/refs/heads/feature/login-page"))
        XCTAssertTrue(relevant("/.git/refs/remotes/origin/main"))
        XCTAssertTrue(relevant("/.git/packed-refs"))
        XCTAssertFalse(relevant("/.git/objects/ab/cdef"))
        XCTAssertFalse(relevant("/.git/logs/refs/heads/main"))
        XCTAssertFalse(relevant("/.git/refs/heads/main.lock"))
        XCTAssertFalse(relevant("/.git/index.lock"))
    }

    func testTheFilesThatDecideTheStatusCount() {
        for name in ["index", "HEAD", "ORIG_HEAD", "MERGE_HEAD"] { XCTAssertTrue(relevant("/.git/" + name), name) }
        XCTAssertFalse(relevant("/.git/FETCH_HEAD"))
        XCTAssertFalse(relevant("/.git/config"))
    }

    func testAFolderToRescanAndReftableCount() {
        XCTAssertTrue(relevant("/.git"))
        XCTAssertTrue(relevant("/.git/refs"))
        XCTAssertTrue(relevant("/.git/reftable/tables.list"))
        XCTAssertTrue(relevant("/.git/reftable"))
        XCTAssertFalse(relevant("/.git/reftable/tables.list.lock"))
    }

    func testRefsAndHeadAreSharedByEveryWorktree() {
        for path in [".git", ".git/refs", ".git/refs/remotes/origin/feature/login-page", ".git/packed-refs", ".git/HEAD",
                     ".git/reftable/tables.list"] {
            XCTAssertTrue(GitWatchPaths.isShared(path), path)
        }
        for path in [".git/index", ".git/worktrees/feature-login-page/HEAD", "src/app.ts", ".git/MERGE_HEAD"] {
            XCTAssertFalse(GitWatchPaths.isShared(path), path)
        }
    }

    func testATaskWorktreesIndexAndHeadCount() {
        XCTAssertTrue(relevant("/.git/worktrees/feature-login-page/index"))
        XCTAssertTrue(relevant("/.git/worktrees/feature-login-page/HEAD"))
        XCTAssertFalse(relevant("/.git/worktrees/feature-login-page/index.lock"))
        XCTAssertFalse(relevant("/.git/worktrees/feature-login-page/logs/HEAD"))
        XCTAssertFalse(relevant("/.git/worktrees/feature-login-page/ORIG_HEAD"))
    }

    func testOutsideGitEverythingButTaskWorktreesCounts() {
        XCTAssertTrue(relevant("/src/app.ts"))
        XCTAssertTrue(relevant(""))
        XCTAssertFalse(relevant("/.worktrees/feature-login-page/src/app.ts"))
        XCTAssertFalse(relevant("/packages/lib/.git/index"))
        XCTAssertTrue(GitWatchPaths.isRelevant("/elsewhere/README.md", root: root))
    }

    func testAChangeUnderWorktreesNamesItsTask() {
        XCTAssertEqual(GitWatchPaths.worktreeName(".git/worktrees/feature-login-page/index"), "feature-login-page")
        XCTAssertNil(GitWatchPaths.worktreeName(".git/index"))
        XCTAssertNil(GitWatchPaths.worktreeName(".worktrees/feature-login-page/src/app.ts"))
    }

    func testAWatcherReportsOnlyWhatItsFilterCounts() {
        let filter = GitWatchPaths.isRelevant
        XCTAssertNil(FolderWatcher.changes([root + "/.git/objects/ab"], root: root, filter: filter))
        XCTAssertEqual(FolderWatcher.changes([root + "/.git/objects/ab", root + "/.git/refs/heads/main"], root: root, filter: filter),
                       [".git/refs/heads/main"])
        XCTAssertEqual(FolderWatcher.changes([root], root: root + "/", filter: filter), [""])
        XCTAssertEqual(FolderWatcher.changes([], root: root, filter: filter), [], "nothing said: something changed")
        XCTAssertEqual(FolderWatcher.changes(["/elsewhere/README.md"], root: root, filter: filter), [], "outside: unknown")
        XCTAssertNil(FolderWatcher.changes([root + "/.git/refs/heads/main"], root: root, filter: FolderWatcher.isRelevant),
                     "the Files panel's filter drops refs")
    }
}
