// Ported from AiTerm (app/Tests/AiTermCoreTests/DiffStatResolverTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// A task worktree's lines against its base: commits, edits and untracked files, from the
/// merge-base; kept for its time, and its merge-base until a ref moves.
@Suite struct DiffStatsTests {
    /// A repo on `main` with one tracked file of three lines, and a task worktree off it.
    private func makeRepo() throws -> (GitRepoFixture, String) {
        let repo = try GitRepoFixture()
        try write("one\ntwo\nthree\n", to: repo.path + "/a.txt")
        try repo.git("add", "."); try repo.git("commit", "-q", "-m", "add a.txt")
        let worktree = repo.path + "/.worktrees/feat"
        try repo.git("worktree", "add", "-q", "-b", "feat/x", worktree)
        return (repo, worktree)
    }

    private func write(_ text: String, to path: String) throws { try text.write(toFile: path, atomically: true, encoding: .utf8) }

    private func commit(_ message: String, in dir: String, _ repo: GitRepoFixture) throws {
        try repo.git(["add", "-A"], in: dir); try repo.git(["commit", "-q", "-m", message], in: dir)
    }

    private func stats(_ repo: GitRepoFixture, now: @escaping @Sendable () -> Date = Date.init,
                       cap: DiffStats.UntrackedCap = .standard) -> DiffStats {
        DiffStats(git: LauncherGit(launcher: repo.launcher), now: now, untrackedCap: cap)
    }

    @Test func aFreshWorktreeHasNoDiff() throws {
        let (repo, worktree) = try makeRepo()
        #expect(stats(repo).diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    @Test func committedAndUncommittedLinesCount() throws {
        let (repo, worktree) = try makeRepo()
        try write("one\nTWO\nthree\nfour\n", to: worktree + "/a.txt")
        try commit("edit", in: worktree, repo)
        try write("one\nTWO\n", to: worktree + "/a.txt")
        #expect(stats(repo).diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 2))
    }

    @Test func untrackedFilesCountTheirLines() throws {
        let (repo, worktree) = try makeRepo()
        try write("x\ny\n", to: worktree + "/new.txt")
        try write("no trailing newline", to: worktree + "/partial.txt")
        try FileManager.default.createSymbolicLink(atPath: worktree + "/zero", withDestinationPath: "/dev/zero")
        #expect(stats(repo).diff(for: worktree, base: "main") == DiffStat(added: 4, removed: 0), "a link is one line, never read")
    }

    @Test func binaryAndIgnoredFilesDoNotCount() throws {
        let (repo, worktree) = try makeRepo()
        try write("ignored.log\n", to: worktree + "/.gitignore")
        try write("a\nb\nc\n", to: worktree + "/ignored.log")
        try Data([0x00, 0x01, 0x0A, 0x02]).write(to: URL(fileURLWithPath: worktree + "/blob.bin"))
        #expect(stats(repo).diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0), ".gitignore itself is one line")
    }

    @Test func measuresFromTheMergeBaseNotTheBaseTip() throws {
        let (repo, worktree) = try makeRepo()
        try write("one\ntwo\nthree\nmain only\n", to: repo.path + "/a.txt")
        try commit("main moves on", in: repo.path, repo)
        #expect(stats(repo).diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    @Test func aStaleLocalBaseUsesOrigins() throws {
        let (repo, worktree) = try makeRepo()
        try write("upstream\n", to: worktree + "/up.txt")
        try commit("upstream", in: worktree, repo)
        try repo.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: worktree)
        try write("mine\nmine\n", to: worktree + "/mine.txt")
        try commit("task", in: worktree, repo)
        #expect(stats(repo).diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
    }

    @Test func noBaseIsNoAnswer() throws {
        let (repo, worktree) = try makeRepo()
        let s = stats(repo)
        #expect(s.diff(for: worktree, base: "") == nil)
        #expect(s.diff(for: worktree, base: "no-such-branch") == nil)
        #expect(s.diff(for: "/definitely/not/here", base: "main") == nil)
    }

    @Test func anAnswerIsKeptForItsTime() throws {
        let clock = TestClock()
        let (repo, worktree) = try makeRepo()
        let s = stats(repo, now: { clock.now })
        #expect(s.diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
        try write("new\n", to: worktree + "/c.txt")
        clock.advance(by: 4)
        #expect(s.diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
        clock.advance(by: 2)
        #expect(s.diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0))
    }

    /// Once an answer expires only `diff` and `ls-files` run again, until a ref the merge-base
    /// came from moves.
    @Test func aMergeBaseIsReusedUntilARefMoves() throws {
        let clock = TestClock()
        let (repo, worktree) = try makeRepo()
        let recording = RecordingGit(real: LauncherGit(launcher: repo.launcher))
        let s = DiffStats(git: recording, now: { clock.now })
        _ = s.diff(for: worktree, base: "main")
        var seen = recording.calls.count
        func expired() -> [String] {
            clock.advance(by: 6)
            _ = s.diff(for: worktree, base: "main")
            defer { seen = recording.calls.count }
            return recording.calls.dropFirst(seen).map { $0[0] }
        }
        #expect(expired() == ["diff", "ls-files"])
        try write("one\ntwo\nthree\nmain only\n", to: repo.path + "/a.txt")
        try commit("main moves on", in: repo.path, repo)
        #expect(expired().contains("merge-base"), "the base branch moved")
        #expect(expired() == ["diff", "ls-files"])
    }

    @Test func untrackedCountingStopsAtItsCaps() throws {
        let (repo, worktree) = try makeRepo()
        for name in ["a", "b", "c", "d", "e"] { try write("x\ny\n", to: worktree + "/\(name).new") }
        #expect(stats(repo).diff(for: worktree, base: "main") == DiffStat(added: 10, removed: 0))
        #expect(stats(repo, cap: .init(files: 3, bytes: 1 << 20)).diff(for: worktree, base: "main") == DiffStat(added: 6, removed: 0))
        #expect(stats(repo, cap: .init(files: 100, bytes: 10)).diff(for: worktree, base: "main") == DiffStat(added: 4, removed: 0))
    }

    @Test func aTimeoutKeepsTheLastAnswerAndBacksOff() throws {
        let clock = TestClock()
        let (repo, worktree) = try makeRepo()
        try write("x\n", to: worktree + "/new.txt")
        let flaky = SwitchableGit(real: LauncherGit(launcher: repo.launcher))
        let s = DiffStats(git: flaky, now: { clock.now })
        #expect(s.diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0))
        try write("y\nz\n", to: worktree + "/more.txt")
        flaky.timingOut = true
        clock.advance(by: 6)
        #expect(s.diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0), "the last known stands")
        flaky.timingOut = false
        let asked = flaky.count
        clock.advance(by: 6)
        #expect(s.diff(for: worktree, base: "main") == DiffStat(added: 1, removed: 0))
        #expect(flaky.count == asked, "left alone within the backoff")
        clock.advance(by: DiffStats.failureBackoff)
        #expect(s.diff(for: worktree, base: "main") == DiffStat(added: 3, removed: 0))
    }

    @Test func aPassForgetsTasksNoLongerPassed() throws {
        let (repo, first) = try makeRepo()
        let second = repo.path + "/.worktrees/other"
        try repo.git("worktree", "add", "-q", "-b", "feat/y", second)
        let a = TaskItem(projectId: UUID(), title: "a", branch: "feat/x", worktreePath: first, baseBranch: "main")
        let b = TaskItem(projectId: UUID(), title: "b", branch: "feat/y", worktreePath: second, baseBranch: "main")
        let recording = RecordingGit(real: LauncherGit(launcher: repo.launcher))
        let s = DiffStats(git: recording, now: { Date(timeIntervalSince1970: 0) })
        #expect(s.diffs(for: [a, b]).count == 2)
        _ = s.diffs(for: [a])
        let before = recording.calls.count
        _ = s.diffs(for: [a])
        #expect(recording.calls.count == before, "a task still passed keeps its answer")
        _ = s.diffs(for: [b])
        #expect(recording.calls.dropFirst(before).contains { $0[0] == "merge-base" }, "a task left out was forgotten")
    }

    /// Every window asks on the same tick: a read already running is not run again beside it.
    @Test func concurrentAsksRunGitOnce() async throws {
        let (repo, worktree) = try makeRepo()
        let held = HeldGit(real: LauncherGit(launcher: repo.launcher), holding: "diff")
        let s = DiffStats(git: held)
        let first = Task.detached { s.diff(for: worktree, base: "main") }
        while held.waiting == 0 { try await Task.sleep(for: .milliseconds(5)) }
        let second = Task.detached { s.diff(for: worktree, base: "main") }
        try await Task.sleep(for: .milliseconds(300))
        let ran = held.count(of: "diff")
        // Let any held call go, so a failing run ends rather than hangs.
        held.release(); held.release()
        #expect(ran == 1, "the second ask ran no diff of its own")
        #expect(await second.value == nil, "it has no answer yet")
        #expect(await first.value == DiffStat(added: 0, removed: 0))
    }

    @Test func gitIsGivenAShortDeadline() throws {
        let (repo, worktree) = try makeRepo()
        let recording = RecordingGit(real: LauncherGit(launcher: repo.launcher))
        _ = DiffStats(git: recording).diff(for: worktree, base: "main")
        #expect(recording.timeout(of: ["diff"]) == DiffStats.gitDeadline)
        #expect(DiffStats.gitDeadline == 10)
    }

    /// git that could not be run is no answer, but no timeout either: it is asked again once the
    /// answer expires, not left alone for the backoff.
    @Test func aFailureThatIsNoTimeoutDoesNotBackOff() throws {
        let clock = TestClock()
        let (repo, worktree) = try makeRepo()
        let failing = SwitchableGit(real: LauncherGit(launcher: repo.launcher))
        failing.throwing = true
        let s = DiffStats(git: failing, now: { clock.now })
        #expect(s.diff(for: worktree, base: "main") == nil)
        failing.throwing = false
        clock.advance(by: 6)
        #expect(s.diff(for: worktree, base: "main") == DiffStat(added: 0, removed: 0))
    }

    /// A worktree whose folder is gone runs no git at all.
    @Test func aDeletedWorktreeRunsNoGit() throws {
        let (repo, worktree) = try makeRepo()
        try FileManager.default.removeItem(atPath: worktree)
        let recording = RecordingGit(real: LauncherGit(launcher: repo.launcher))
        #expect(DiffStats(git: recording).diff(for: worktree, base: "main") == nil)
        #expect(recording.calls.isEmpty)
    }

    @Test func lineCountMatchesGit() {
        #expect(DiffStats.lineCount(Data("a\nb\n".utf8)) == 2)
        #expect(DiffStats.lineCount(Data("a\nb".utf8)) == 2)
        #expect(DiffStats.lineCount(Data("\n\n\n".utf8)) == 3)
        #expect(DiffStats.lineCount(Data()) == nil)
        #expect(DiffStats.lineCount(Data([0x61, 0x00, 0x0A])) == nil)
    }
}

/// git that answers every call as timed out while `timingOut` is set, and counts the calls.
final class SwitchableGit: GitCommands, @unchecked Sendable {
    private let lock = NSLock()
    private var on = false, throwsNow = false, calls = 0
    let real: LauncherGit
    init(real: LauncherGit) { self.real = real }
    var timingOut: Bool {
        get { lock.lock(); defer { lock.unlock() }; return on }
        set { lock.lock(); on = newValue; lock.unlock() }
    }
    /// Throws, as a git that could not be launched does.
    var throwing: Bool {
        get { lock.lock(); defer { lock.unlock() }; return throwsNow }
        set { lock.lock(); throwsNow = newValue; lock.unlock() }
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func git(_ args: [String], in directory: String, remote: Bool, timeout: TimeInterval?) throws -> ChildOutput {
        lock.lock(); calls += 1; let failing = on, throwing = throwsNow; lock.unlock()
        if throwing { throw CocoaError(.executableNotLoadable) }
        if failing { return ChildOutput(status: 15, stdout: "", stderr: "", timedOut: true) }
        return try real.git(args, in: directory, remote: remote, timeout: timeout)
    }
}

/// git that holds every `holding` call until released, and counts each command.
final class HeldGit: GitCommands, @unchecked Sendable {
    private let lock = NSLock(), gate = DispatchSemaphore(value: 0)
    private var counts: [String: Int] = [:], held = 0
    let real: LauncherGit, holding: String
    init(real: LauncherGit, holding: String) { self.real = real; self.holding = holding }
    var waiting: Int { lock.lock(); defer { lock.unlock() }; return held }
    func count(of command: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[command, default: 0] }
    func release() { gate.signal() }
    func git(_ args: [String], in directory: String, remote: Bool, timeout: TimeInterval?) throws -> ChildOutput {
        lock.lock(); counts[args[0], default: 0] += 1; let holds = args[0] == holding; if holds { held += 1 }; lock.unlock()
        if holds { gate.wait() }
        return try real.git(args, in: directory, remote: remote, timeout: timeout)
    }
}
