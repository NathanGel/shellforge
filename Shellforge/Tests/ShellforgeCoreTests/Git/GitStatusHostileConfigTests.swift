import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// The reads Shellforge makes on its own run nothing a repository's own config names: a `.git`
/// that came in an archive can set `core.fsmonitor` to any command, and plain `git status` runs it.
@Suite struct GitStatusHostileConfigTests {
    /// A repository whose `core.fsmonitor` is a script that leaves `marker` behind, and a task
    /// worktree with an edit and an untracked file, so every read has something to look at.
    private func hostileRepo() throws -> (GitRepoFixture, worktree: String, marker: String) {
        let repo = try GitRepoFixture()
        let marker = (repo.path as NSString).deletingLastPathComponent + "/fsmonitor-ran"
        let script = (repo.path as NSString).deletingLastPathComponent + "/fsmonitor.sh"
        try "#!/bin/sh\ntouch '\(marker)'\nexit 1\n".write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        try "one\n".write(toFile: repo.path + "/a.txt", atomically: true, encoding: .utf8)
        try repo.git("add", "a.txt")
        try repo.git("commit", "-q", "-m", "a")
        let worktree = repo.path + "/.worktrees/feat"
        try repo.git("worktree", "add", "-q", "-b", "feat/x", worktree)
        try "one\ntwo\n".write(toFile: worktree + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: worktree + "/b.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: repo.path + "/c.txt", atomically: true, encoding: .utf8)
        try repo.git("config", "core.fsmonitor", script)
        return (repo, worktree, marker)
    }

    @Test func aHostileFsmonitorIsNotRun() throws {
        let (repo, worktree, marker) = try hostileRepo()
        let ran = { FileManager.default.fileExists(atPath: marker) }
        // The fixture is live: git as configured runs the script.
        _ = try repo.git("status", "--porcelain")
        #expect(ran(), "plain git status runs the repository's fsmonitor")
        try FileManager.default.removeItem(atPath: marker)

        let status = try GitStatus.read(repo.path, launcher: repo.launcher)
        #expect(status.unstaged.map(\.path) == ["c.txt"])
        #expect(!ran(), "the Git panel's status")

        guard case .git(let paths, _) = ProjectFiles.list(repo.path, launcher: repo.launcher) else {
            Issue.record("not a git listing"); return
        }
        #expect(paths.contains("c.txt"))
        #expect(!ran(), "the Files panel's ls-files")

        #expect(DiffStats(launcher: repo.launcher).diff(for: worktree, base: "main") == DiffStat(added: 2, removed: 0))
        #expect(!ran(), "a task's diff badge")

        let task = TaskItem(projectId: repo.project.id, title: "feat", branch: "feat/x", worktreePath: worktree, baseBranch: "main")
        #expect(try TaskRemoval.hasUnsavedWork(task: task, project: repo.project, launcher: repo.launcher))
        #expect(!ran(), "Remove's unsaved-work question")

        _ = try GitActions.branches(in: repo.path, launcher: repo.launcher)
        _ = Repository.branches(of: repo.path, launcher: repo.launcher)
        _ = try ExistingWorktrees.list(project: repo.project, taken: [], launcher: repo.launcher)
        #expect(!ran(), "branch and worktree lists")
    }

    /// A filter driver the repository's config defines, named by an attribute, is a command
    /// `git status` and `git diff` run on file contents. The automatic reads switch it off.
    @Test func aHostileCleanFilterIsNotRun() throws {
        let (repo, worktree, _) = try hostileRepo()
        try repo.git("config", "--unset", "core.fsmonitor")
        let marker = (repo.path as NSString).deletingLastPathComponent + "/filter-ran"
        try repo.git("config", "filter.evil.clean", "touch '\(marker)'; cat")
        try repo.git("config", "filter.evil.process", "sh -c \"touch '\(marker)'\"")
        for folder in [repo.path, worktree] {
            try "*.txt filter=evil\n".write(toFile: folder + "/.gitattributes", atomically: true, encoding: .utf8)
        }
        let ran = { FileManager.default.fileExists(atPath: marker) }
        _ = try? repo.launcher.run("git", ["-C", worktree, "diff", "--numstat", "main"])
        #expect(ran(), "plain git diff runs the repository's filter")
        try FileManager.default.removeItem(atPath: marker)

        _ = try GitStatus.read(repo.path, launcher: repo.launcher)
        _ = try GitStatus.read(worktree, launcher: repo.launcher)
        #expect(!ran(), "the Git panel's status")
        #expect(DiffStats(launcher: repo.launcher).diff(for: worktree, base: "main") != nil)
        #expect(!ran(), "a task's diff badge")
        let task = TaskItem(projectId: repo.project.id, title: "feat", branch: "feat/x", worktreePath: worktree, baseBranch: "main")
        #expect(try TaskRemoval.hasUnsavedWork(task: task, project: repo.project, launcher: repo.launcher))
        #expect(!ran(), "Remove's unsaved-work question")
    }

    /// Only the repository's own drivers are switched off, and not one that runs git-lfs.
    @Test func gitLfsAndThePersonsOwnDriversKeepRunning() throws {
        let repo = try GitRepoFixture()
        try repo.git("config", "filter.lfs.process", "git-lfs filter-process")
        try repo.git("config", "filter.lfs.clean", "git-lfs clean -- %f")
        #expect(AutomaticGitRead.filterOverrides(repo.path, launcher: repo.launcher).isEmpty)
        // What `git lfs install --local --skip-smudge` writes.
        try repo.git("config", "filter.lfs.smudge", "git-lfs smudge --skip -- %f")
        try repo.git("config", "filter.lfs.process", "git-lfs filter-process --skip")
        #expect(AutomaticGitRead.filterOverrides(repo.path, launcher: repo.launcher).isEmpty)
        try repo.git("config", "filter.my.tool.clean", "cat")
        #expect(AutomaticGitRead.filterOverrides(repo.path, launcher: repo.launcher)
            == ["-c", "filter.my.tool.clean=", "-c", "filter.my.tool.smudge=", "-c", "filter.my.tool.process=", "-c", "filter.my.tool.required=false"])
    }

    /// Every automatic read's options turn off fsmonitor and hooks, before the subcommand.
    @Test func automaticReadsTurnOffFsmonitorAndHooks() {
        #expect(AutomaticGitRead.arguments(["status"], in: "/tmp/demo")
            == ["-C", "/tmp/demo", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "status"])
    }
}
