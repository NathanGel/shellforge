import XCTest
@testable import ShellforgeCore

final class GitStatusTests: XCTestCase {
    private func nul(_ lines: String...) -> String { lines.joined(separator: "\0") + "\0" }
    private let sha = "abc1234def5678abc1234def5678abc1234def56"

    func testACleanBranchWithUpstreamParses() {
        let status = GitStatus.parse(nul("# branch.oid \(sha)", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1"))
        XCTAssertEqual(status.head, .branch("main"))
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertFalse(status.hasChanges)
    }

    func testAnUnbornBranchParses() {
        let status = GitStatus.parse(nul("# branch.oid (initial)", "# branch.head main"))
        XCTAssertEqual(status.head, .unborn("main"))
        XCTAssertNil(status.upstream)
    }

    func testADetachedHeadParses() {
        let status = GitStatus.parse(nul("# branch.oid \(sha)", "# branch.head (detached)"))
        XCTAssertEqual(status.head, .detached(sha: "abc1234"))
    }

    func testStagedAndUnstagedOfOneFileBothShow() {
        let status = GitStatus.parse(nul("1 MM N... 100644 100644 100644 \(sha) \(sha) src/app.ts"))
        XCTAssertEqual(status.staged, [GitChange(path: "src/app.ts", letter: .modified)])
        XCTAssertEqual(status.unstaged, [GitChange(path: "src/app.ts", letter: .modified)])
        XCTAssertTrue(status.hasChanges)
    }

    func testOddNamesAndRenamesParse() {
        let status = GitStatus.parse(nul(
            "2 R. N... 100644 100644 100644 \(sha) \(sha) R100 my file's $x.md", "old name.md",
            "? ünïcode.txt"))
        XCTAssertEqual(status.staged, [GitChange(path: "my file's $x.md", originalPath: "old name.md", letter: .renamed)])
        XCTAssertTrue(status.unstaged.contains(GitChange(path: "ünïcode.txt", letter: .untracked)))
        XCTAssertEqual(status.unstaged.count, 1)
    }

    func testConflictsParse() {
        let status = GitStatus.parse(nul("u UU N... 100644 100644 100644 100644 \(sha) \(sha) \(sha) README.md"))
        XCTAssertEqual(status.conflicted, [GitChange(path: "README.md", letter: .conflicted)])
        XCTAssertTrue(status.staged.isEmpty)
        XCTAssertTrue(status.unstaged.isEmpty)
    }

    func testWorktreesAreLeftOut() throws {
        let repo = try GitRepoFixture()
        let nested = "\(repo.path)/.worktrees/abc"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try "x".write(toFile: "\(nested)/x", atomically: true, encoding: .utf8)
        try "y".write(toFile: "\(repo.path)/README.md", atomically: true, encoding: .utf8)
        let status = try GitStatus.read(repo.path, launcher: repo.launcher)
        XCTAssertEqual(status.unstaged.map(\.path), ["README.md"])
    }

    func testANonRepositoryThrowsWithGitsWords() throws {
        let repo = try GitRepoFixture()
        XCTAssertThrowsError(try GitStatus.read("\(repo.path)/missing-folder", launcher: repo.launcher)) {
            XCTAssertFalse(($0 as? GitFailure)?.message.isEmpty ?? true)
        }
    }
}
