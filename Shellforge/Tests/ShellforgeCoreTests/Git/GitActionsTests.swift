import XCTest
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

final class GitActionsTests: XCTestCase {
    private func write(_ name: String, _ text: String = "x\n", in repo: GitRepoFixture) throws {
        let url = URL(fileURLWithPath: repo.path).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func status(_ repo: GitRepoFixture) throws -> GitStatus { try GitStatus.read(repo.path, launcher: repo.launcher) }

    private func tracked(_ repo: GitRepoFixture, _ names: String...) throws {
        for name in names { try write(name, in: repo) }
        try repo.git(["add", "-A"], in: repo.path)
        try repo.git("commit", "-q", "-m", "add")
    }

    /// A bare origin next to the repository, with the repository's branch pushed and tracking it.
    @discardableResult
    private func withOrigin(_ repo: GitRepoFixture, branch: String = "main") throws -> String {
        let origin = URL(fileURLWithPath: repo.path).deletingLastPathComponent().appendingPathComponent("origin.git").path
        try repo.git(["init", "-q", "--bare", "-b", branch, origin], in: repo.path)
        try repo.git("remote", "add", "origin", origin)
        try repo.git("push", "-q", "-u", "origin", branch)
        return origin
    }

    /// Another clone of origin, with one more commit pushed.
    private func moveOriginOn(_ origin: String, from repo: GitRepoFixture, file: String = "other.md") throws {
        let clone = URL(fileURLWithPath: origin).deletingLastPathComponent().appendingPathComponent("clone-\(UUID().uuidString)").path
        try repo.git(["clone", "-q", origin, clone], in: repo.path)
        try "y\n".write(toFile: "\(clone)/\(file)", atomically: true, encoding: .utf8)
        try repo.git(["add", "-A"], in: clone)
        try repo.git(["commit", "-q", "-m", "remote"], in: clone)
        try repo.git(["push", "-q"], in: clone)
    }

    private func failure(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return (error as? GitFailure)?.message }
    }

    func testStagingAnOddNameStagesThatFile() throws {
        let repo = try GitRepoFixture()
        try write("my file's $x.md", in: repo)
        try write("README.md", in: repo)
        try GitActions.stage(["my file's $x.md"], in: repo.path, launcher: repo.launcher)
        let s = try status(repo)
        XCTAssertEqual(s.staged.map(\.path), ["my file's $x.md"])
        XCTAssertEqual(s.unstaged.map(\.path), ["README.md"])
    }

    /// `app/[id]/page.tsx` beside `app/i/page.tsx`: as a glob, the first would match both.
    private func bracketRepo() throws -> GitRepoFixture {
        let repo = try GitRepoFixture()
        try tracked(repo, "app/[id]/page.tsx", "app/i/page.tsx")
        try write("app/[id]/page.tsx", "changed\n", in: repo)
        try write("app/i/page.tsx", "changed\n", in: repo)
        return repo
    }

    private let bracket = "app/[id]/page.tsx"

    func testStagingABracketPathStagesOnlyThatFile() throws {
        let repo = try bracketRepo()
        try GitActions.stage([bracket], in: repo.path, launcher: repo.launcher)
        XCTAssertEqual(try status(repo).staged.map(\.path), [bracket])
    }

    func testUnstagingABracketPathUnstagesOnlyThatFile() throws {
        let repo = try bracketRepo()
        try GitActions.stage([bracket, "app/i/page.tsx"], in: repo.path, launcher: repo.launcher)
        try GitActions.unstage([bracket], in: repo.path, launcher: repo.launcher)
        XCTAssertEqual(try status(repo).staged.map(\.path), ["app/i/page.tsx"])
    }

    func testDiscardingABracketPathDiscardsOnlyThatFile() throws {
        let repo = try bracketRepo()
        let change = try XCTUnwrap(try status(repo).unstaged.first { $0.path == bracket })
        try GitActions.discard(change, in: repo.path, launcher: repo.launcher)
        XCTAssertEqual(try status(repo).unstaged.map(\.path), ["app/i/page.tsx"])
        XCTAssertEqual(try String(contentsOfFile: "\(repo.path)/app/i/page.tsx", encoding: .utf8), "changed\n")
    }

    func testTheDiffOfABracketPathShowsThatFile() throws {
        let repo = try bracketRepo()
        let line = GitActions.diffLine(for: GitChange(path: bracket, letter: .modified), staged: false)
        let out = try repo.launcher.run("/bin/sh", ["-c", "cd \(AgentCommand.shellWord(repo.path)) && \(line) | cat"])
        XCTAssertTrue(out.stdout.contains(bracket), out.stdout)
        XCTAssertFalse(out.stdout.contains("app/i/page.tsx"), out.stdout)
    }

    func testStageAllAndUnstageAllTakeEverything() throws {
        let repo = try bracketRepo()
        try write("new.md", in: repo)
        try GitActions.stageAll(in: repo.path, launcher: repo.launcher)
        XCTAssertEqual(Set(try status(repo).staged.map(\.path)), [bracket, "app/i/page.tsx", "new.md"])
        XCTAssertTrue(try status(repo).unstaged.isEmpty)
        try GitActions.unstageAll(in: repo.path, launcher: repo.launcher)
        XCTAssertTrue(try status(repo).staged.isEmpty)
    }

    func testUnstagingPutsItBack() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "src/app.ts")
        try write("src/app.ts", "changed\n", in: repo)
        try GitActions.stage(["src/app.ts"], in: repo.path, launcher: repo.launcher)
        try GitActions.unstage(["src/app.ts"], in: repo.path, launcher: repo.launcher)
        let s = try status(repo)
        XCTAssertTrue(s.staged.isEmpty)
        XCTAssertEqual(s.unstaged.map(\.path), ["src/app.ts"])
    }

    func testUnstagingOnAnUnbornBranch() throws {
        let root = TestScratch.root.appendingPathComponent("shellforge-unborn-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let seed = try GitRepoFixture()
        try seed.git(["init", "-q", "-b", "main", root], in: seed.path)
        try "x\n".write(toFile: "\(root)/README.md", atomically: true, encoding: .utf8)
        try GitActions.stage(["README.md"], in: root, launcher: seed.launcher)
        try GitActions.unstage(["README.md"], in: root, launcher: seed.launcher)
        let s = try GitStatus.read(root, launcher: seed.launcher)
        XCTAssertTrue(s.staged.isEmpty)
        XCTAssertEqual(s.unstaged.map(\.path), ["README.md"])
    }

    func testDiscardRestoresATrackedFile() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "src/app.ts")
        try write("src/app.ts", "changed\n", in: repo)
        let change = try XCTUnwrap(try status(repo).unstaged.first)
        try GitActions.discard(change, in: repo.path, launcher: repo.launcher)
        XCTAssertEqual(try String(contentsOfFile: "\(repo.path)/src/app.ts", encoding: .utf8), "x\n")
        XCTAssertFalse(try status(repo).hasChanges)
    }

    private func discard(_ change: GitChange, _ repo: GitRepoFixture) throws -> [URL] {
        var trashed: [URL] = []
        try GitActions.discard(change, in: repo.path, launcher: repo.launcher) { trashed.append($0) }
        return trashed
    }

    private func unstaged(_ repo: GitRepoFixture) throws -> GitChange { try XCTUnwrap(try status(repo).unstaged.first) }

    func testDiscardingAnIntentToAddFileKeepsItInTheTrashNotBlanked() throws {
        let repo = try GitRepoFixture()
        try write("n.md", "precious\n", in: repo)
        try repo.git("add", "-N", "n.md")
        let trashed = try discard(try unstaged(repo), repo)
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["n.md"])
        XCTAssertEqual(try String(contentsOfFile: "\(repo.path)/n.md", encoding: .utf8), "precious\n")
        // The fake trash left the file, so it now shows as untracked: not in the index.
        XCTAssertEqual(try status(repo).unstaged.map(\.letter), [.untracked])
        XCTAssertEqual(try repo.git("ls-files"), "")
    }

    func testDiscardingAnIntentToAddRenameTrashesTheNewNameAndRestoresTheOld() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "old.md")
        try repo.git("mv", "old.md", "new.md")
        try repo.git("reset", "-q")
        try repo.git("add", "-N", "new.md")
        let change = try unstaged(repo)
        XCTAssertEqual(change.letter, .renamed)
        let trashed = try discard(change, repo)
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["new.md"])
        XCTAssertEqual(try String(contentsOfFile: "\(repo.path)/old.md", encoding: .utf8), "x\n")
    }

    func testDiscardingARenamedThenEditedFileRestoresTheNewPathOnly() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "old.md")
        try repo.git("mv", "old.md", "new.md")
        try write("new.md", "edited\n", in: repo)
        let change = try unstaged(repo)
        XCTAssertEqual(change.originalPath, "old.md")
        _ = try discard(change, repo)
        XCTAssertEqual(try String(contentsOfFile: "\(repo.path)/new.md", encoding: .utf8), "x\n")
        XCTAssertEqual(try status(repo).staged.first?.letter, .renamed)
    }

    func testDiscardRestoresADeletedFile() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "src/app.ts")
        try FileManager.default.removeItem(atPath: "\(repo.path)/src/app.ts")
        _ = try discard(try unstaged(repo), repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(repo.path)/src/app.ts"))
    }

    func testDiscardRestoresATypeChange() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "src/app.ts")
        try FileManager.default.removeItem(atPath: "\(repo.path)/src/app.ts")
        try FileManager.default.createSymbolicLink(atPath: "\(repo.path)/src/app.ts", withDestinationPath: "README.md")
        let change = try unstaged(repo)
        XCTAssertEqual(change.letter, .typeChanged)
        _ = try discard(change, repo)
        XCTAssertEqual(try String(contentsOfFile: "\(repo.path)/src/app.ts", encoding: .utf8), "x\n")
    }

    func testDiscardKeepsTheStagedPartOfAFile() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "src/app.ts")
        try write("src/app.ts", "staged\n", in: repo)
        try repo.git("add", "src/app.ts")
        try write("src/app.ts", "worktree\n", in: repo)
        _ = try discard(try unstaged(repo), repo)
        XCTAssertEqual(try String(contentsOfFile: "\(repo.path)/src/app.ts", encoding: .utf8), "staged\n")
        XCTAssertEqual(try status(repo).staged.map(\.path), ["src/app.ts"])
    }

    func testDiscardRefusesAConflict() throws {
        let repo = try GitRepoFixture()
        var trashed: [URL] = []
        let message = failure {
            try GitActions.discard(GitChange(path: "src/app.ts", letter: .conflicted), in: repo.path, launcher: repo.launcher) { trashed.append($0) }
        }
        XCTAssertNotNil(message)
        XCTAssertTrue(trashed.isEmpty)
    }

    func testDiscardingAnUntrackedFileTrashesIt() throws {
        let repo = try GitRepoFixture()
        try write("README.md", in: repo)
        let trashed = try discard(try unstaged(repo), repo)
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["README.md"])
    }

    func testUnstagingARenameTakesBothPaths() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "old.md")
        try repo.git("mv", "old.md", "new.md")
        let change = try XCTUnwrap(try status(repo).staged.first)
        try GitActions.unstage(change, in: repo.path, launcher: repo.launcher)
        let s = try status(repo)
        XCTAssertTrue(s.staged.isEmpty)
        XCTAssertEqual(Set(s.unstaged.map(\.path)), ["old.md", "new.md"])
    }

    func testUnstagingAnEditedAddedFileOnAnUnbornBranch() throws {
        let seed = try GitRepoFixture()
        let root = URL(fileURLWithPath: seed.path).deletingLastPathComponent().appendingPathComponent("fresh2").path
        try seed.git(["init", "-q", "-b", "main", root], in: seed.path)
        try "a\n".write(toFile: "\(root)/README.md", atomically: true, encoding: .utf8)
        try seed.git(["add", "README.md"], in: root)
        try "b\n".write(toFile: "\(root)/README.md", atomically: true, encoding: .utf8)
        try GitActions.unstage(["README.md"], in: root, launcher: seed.launcher)
        XCTAssertTrue(try GitStatus.read(root, launcher: seed.launcher).staged.isEmpty)
    }

    func testSmartCommitLeavesTaskWorktreesOut() throws {
        let repo = try GitRepoFixture()
        try repo.git("worktree", "add", "-q", ".worktrees/abc", "-b", "abc")
        try write("README.md", in: repo)
        try GitActions.commit(message: "docs", in: repo.path, status: try status(repo), launcher: repo.launcher)
        XCTAssertEqual(try repo.git("ls-files", ".worktrees"), "")
        XCTAssertEqual(try repo.git("show", "--name-only", "--format=", "HEAD"), "README.md")
    }

    func testAFailedSmartCommitPutsTheIndexBack() throws {
        let repo = try GitRepoFixture()
        let hook = "\(repo.path)/.git/hooks/commit-msg"
        try "#!/bin/sh\nexit 1\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        try write("README.md", in: repo)
        XCTAssertNotNil(failure { try GitActions.commit(message: "docs", in: repo.path, status: try status(repo), launcher: repo.launcher) })
        let s = try status(repo)
        XCTAssertTrue(s.staged.isEmpty)
        XCTAssertEqual(s.unstaged.map(\.path), ["README.md"])
    }

    func testPushNeedsABranch() throws {
        let repo = try GitRepoFixture()
        for head in [GitStatus.Head.detached(sha: "abc1234"), .unborn("main")] {
            var s = try status(repo)
            s.head = head
            XCTAssertEqual(failure { try GitActions.push(in: repo.path, status: s, launcher: repo.launcher) },
                           "Commit on a branch before pushing.")
        }
    }

    func testPlainWordsForPushRefusals() {
        let hook = "! [remote rejected] HEAD -> main (pre-receive hook declined)\nerror: failed to push some refs"
        XCTAssertEqual(GitActions.plainWords(stderr: hook, action: "push"), "git: ! [remote rejected] HEAD -> main (pre-receive hook declined)")
        XCTAssertEqual(GitActions.plainWords(stderr: " ! [rejected] main -> main (fetch first)", action: "push"),
                       "The remote has commits this branch doesn’t. Pull first, then push.")
    }

    func testPlainWordsSkipHintsAndHideCredentials() {
        let stderr = "\nhint: waiting\nfatal: unable to access 'https://user:token@example.com/acme-web.git/': Could not resolve host"
        XCTAssertEqual(GitActions.plainWords(stderr: stderr, action: "pull"),
                       "Git couldn’t reach origin: fatal: unable to access 'https://example.com/acme-web.git/': Could not resolve host")
    }

    func testSmartCommitTakesEverythingWhenNothingIsStaged() throws {
        let repo = try GitRepoFixture()
        try tracked(repo, "src/app.ts")
        try write("src/app.ts", "changed\n", in: repo)
        try write("README.md", in: repo)
        try GitActions.commit(message: "both", in: repo.path, status: try status(repo), launcher: repo.launcher)
        XCTAssertFalse(try status(repo).hasChanges)
        XCTAssertEqual(try repo.git("log", "-1", "--format=%s"), "both")
    }

    func testACommitWithStagedFilesTakesOnlyThose() throws {
        let repo = try GitRepoFixture()
        try write("src/app.ts", in: repo)
        try write("README.md", in: repo)
        try GitActions.stage(["README.md"], in: repo.path, launcher: repo.launcher)
        try GitActions.commit(message: "docs", in: repo.path, status: try status(repo), launcher: repo.launcher)
        XCTAssertEqual(try status(repo).unstaged.map(\.path), ["src/app.ts"])
        XCTAssertEqual(try repo.git("show", "--name-only", "--format=", "HEAD"), "README.md")
    }

    func testAnEmptyMessageCommitsNothing() throws {
        let repo = try GitRepoFixture()
        try write("README.md", in: repo)
        let before = try repo.git("rev-parse", "HEAD")
        XCTAssertNotNil(failure { try GitActions.commit(message: "  \n", in: repo.path, status: try status(repo), launcher: repo.launcher) })
        XCTAssertEqual(try repo.git("rev-parse", "HEAD"), before)
        XCTAssertEqual(try status(repo).unstaged.map(\.path), ["README.md"])
    }

    func testTheFirstCommitWorks() throws {
        let seed = try GitRepoFixture()
        let root = URL(fileURLWithPath: seed.path).deletingLastPathComponent().appendingPathComponent("fresh").path
        try seed.git(["init", "-q", "-b", "main", root], in: seed.path)
        try "x\n".write(toFile: "\(root)/README.md", atomically: true, encoding: .utf8)
        let s = try GitStatus.read(root, launcher: seed.launcher)
        XCTAssertEqual(s.head, .unborn("main"))
        try GitActions.commit(message: "first", in: root, status: s, launcher: seed.launcher)
        XCTAssertEqual(try GitStatus.read(root, launcher: seed.launcher).head, .branch("main"))
    }

    func testABranchWithoutUpstreamPublishes() throws {
        let repo = try GitRepoFixture()
        let origin = URL(fileURLWithPath: repo.path).deletingLastPathComponent().appendingPathComponent("origin.git").path
        try repo.git(["init", "-q", "--bare", origin], in: repo.path)
        try repo.git("remote", "add", "origin", origin)
        try repo.git("checkout", "-q", "-b", "feature/login-page")
        let s = try status(repo)
        XCTAssertNil(s.upstream)
        try GitActions.push(in: repo.path, status: s, launcher: repo.launcher)
        XCTAssertEqual(try status(repo).upstream, "origin/feature/login-page")
    }

    func testARejectedPushSaysPullFirst() throws {
        let repo = try GitRepoFixture()
        let origin = try withOrigin(repo)
        try moveOriginOn(origin, from: repo)
        try tracked(repo, "src/app.ts")
        let message = failure { try GitActions.push(in: repo.path, status: try status(repo), launcher: repo.launcher) }
        XCTAssertEqual(message, "The remote has commits this branch doesn’t. Pull first, then push.")
    }

    func testPullFastForwards() throws {
        let repo = try GitRepoFixture()
        let origin = try withOrigin(repo)
        try moveOriginOn(origin, from: repo)
        try GitActions.pull(in: repo.path, launcher: repo.launcher)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(repo.path)/other.md"))
    }

    func testADivergedPullChangesNothing() throws {
        let repo = try GitRepoFixture()
        let origin = try withOrigin(repo)
        try moveOriginOn(origin, from: repo)
        try tracked(repo, "src/app.ts")
        let before = try repo.git("rev-parse", "HEAD")
        let message = failure { try GitActions.pull(in: repo.path, launcher: repo.launcher) }
        XCTAssertEqual(message, "This branch and its upstream have both moved. Pull in a terminal to merge or rebase.")
        XCTAssertEqual(try repo.git("rev-parse", "HEAD"), before)
    }

    func testAnUnreachableRemoteSaysSo() throws {
        let repo = try GitRepoFixture()
        try repo.git("remote", "add", "origin", "\(repo.path)/../missing.git")
        let message = failure { try GitActions.push(in: repo.path, status: try status(repo), launcher: repo.launcher) }
        XCTAssertTrue(try XCTUnwrap(message).hasPrefix("Git couldn’t reach origin:"), message ?? "")
    }

    func testALockedIndexSaysAnotherGitIsRunning() throws {
        let repo = try GitRepoFixture()
        try write("README.md", in: repo)
        FileManager.default.createFile(atPath: "\(repo.path)/.git/index.lock", contents: nil)
        let message = failure { try GitActions.stage(["README.md"], in: repo.path, launcher: repo.launcher) }
        XCTAssertEqual(message, "Another git is running in this repository. Try again when it’s done.")
    }

    func testBranchesListsLocalThenRemote() throws {
        let repo = try GitRepoFixture()
        try withOrigin(repo)
        try repo.git("checkout", "-q", "-b", "feature/login-page")
        try repo.git("push", "-q", "origin", "feature/login-page")
        try repo.git("checkout", "-q", "-b", "ABC-123")
        try repo.git("push", "-q", "origin", "ABC-123")
        try repo.git("checkout", "-q", "main")
        try repo.git("branch", "-q", "-D", "ABC-123")
        try repo.git(["remote", "set-head", "origin", "main"], in: repo.path)
        let branches = try GitActions.branches(in: repo.path, launcher: repo.launcher)
        XCTAssertEqual(branches.map(\.title), ["feature/login-page", "main", "origin/ABC-123"])
        XCTAssertEqual(branches.last, GitBranch(title: "origin/ABC-123", name: "ABC-123", remote: "origin"))
    }

    func testDiffLinesQuoteOddNames() {
        XCTAssertEqual(GitActions.diffLine(for: GitChange(path: "src/app.ts", letter: .modified), staged: false),
                       "git diff -- ':(literal)src/app.ts'")
        XCTAssertEqual(GitActions.diffLine(for: GitChange(path: "my file's $x.md", letter: .modified), staged: true),
                       "git diff --staged -- ':(literal)my file'\\''s $x.md'")
        XCTAssertEqual(GitActions.diffLine(for: GitChange(path: "src/main.ts", originalPath: "src/app.ts", letter: .renamed), staged: true),
                       "git diff --staged -M -- ':(literal)src/app.ts' ':(literal)src/main.ts'")
        XCTAssertEqual(GitActions.diffLine(for: GitChange(path: "new file.md", letter: .untracked), staged: false),
                       "git diff --no-index -- /dev/null 'new file.md'")
    }
}
