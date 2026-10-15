import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// A create that hangs in the repository's own checkout hook — a pre-commit `uv sync` — can be
/// stopped: the hook and everything it started end, and nothing is left behind.
@Suite struct TaskCreationCancelTests {
    /// A post-checkout hook that says it started, then takes its time, with a child of its own.
    private func slowHook(in repo: GitRepoFixture, marker: String, childPid: String) throws {
        let hook = "\(repo.path)/.git/hooks/post-checkout"
        try "#!/bin/sh\n/bin/sleep 60 &\necho $! > '\(childPid)'\ntouch '\(marker)'\nwait\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
    }

    private func draft() -> TaskDraft {
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        draft.setTitle("Slow checkout")
        return draft
    }

    private func waitFor(_ path: String) async -> Bool {
        await eventually(describing: "\(path) to appear") { FileManager.default.fileExists(atPath: path) }
    }

    @Test func cancellingDuringTheCheckoutHookStopsItAndLeavesNothing() async throws {
        let repo = try GitRepoFixture()
        let marker = "\(repo.path)/../hook-started", childPid = "\(repo.path)/../hook-child"
        try slowHook(in: repo, marker: marker, childPid: childPid)
        let cancellation = CreationCancellation()
        let draft = draft()
        let project = repo.project, launcher = repo.launcher
        let creating = Task.detached {
            try TaskWorktrees.create(draft: draft, in: project, launcher: launcher, cancellation: cancellation)
        }
        #expect(await waitFor(marker), "the hook ran")
        cancellation.cancel()
        await #expect(throws: CreationCancelled.self) { try await creating.value }
        let pid = try #require(Int32(String(contentsOfFile: childPid, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually(describing: "the hook's child to end") { kill(pid, 0) != 0 })
        #expect(!FileManager.default.fileExists(atPath: "\(repo.path)/.worktrees/\(draft.worktreeSlug)"), "no worktree left")
        #expect((try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(draft.branch)")) == nil, "no branch left")
    }

    @Test func aCreateSaysWhatItIsDoingAndWhetherTheRepositorysHookRuns() throws {
        let repo = try GitRepoFixture()
        let hook = "\(repo.path)/.git/hooks/post-checkout"
        try "#!/bin/sh\nexit 0\n".write(toFile: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let steps = Locked<[CreationStep]>([])
        _ = try TaskWorktrees.create(draft: draft(), in: repo.project, launcher: repo.launcher,
                                     progress: { step in steps.withLock { $0.append(step) } })
        #expect(steps.withLock { $0 }.last == .creatingWorktree(runsHook: true))
    }

    @Test func aCancelledCreateStartsNothing() throws {
        let repo = try GitRepoFixture()
        let cancellation = CreationCancellation()
        cancellation.cancel()
        #expect(throws: CreationCancelled.self) {
            try TaskWorktrees.create(draft: draft(), in: repo.project, launcher: repo.launcher, cancellation: cancellation)
        }
        #expect(!FileManager.default.fileExists(atPath: "\(repo.path)/.worktrees"))
    }
}
