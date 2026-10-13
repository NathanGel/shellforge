import Foundation
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// A fresh repository with one commit on `branch`, and a launcher whose environment is a
/// hermetic git: no user config, a fixed identity.
struct GitRepoFixture {
    let path: String
    let launcher: CommandLauncher

    init(branch: String = "main") throws {
        let root = TestScratch.root.appendingPathComponent("shellforge-repo-\(UUID().uuidString)").path
        path = "\(root)/repo"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let env = ["PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        launcher = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
        _ = try git("init", "-q", "-b", branch)
        _ = try git("commit", "-q", "--allow-empty", "-m", "first")
    }

    /// A project at the repository, as the sidebar would add it.
    var project: Project { Project(name: "repo", path: path) }

    @discardableResult
    func git(_ args: String...) throws -> String { try git(args, in: path) }

    /// git run in `directory` — a worktree of this repository, say.
    @discardableResult
    func git(_ args: [String], in directory: String) throws -> String {
        let out = try launcher.run("git", ["-C", directory] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
