import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// The bug this package exists for: an app opened from the Dock runs `git worktree add`, git runs
/// the repository's `post-checkout` hook, the hook calls `uv` from `~/.local/bin`, and under
/// launchd's `PATH` it fails with "uv: command not found" while the same command works in a terminal.
@Suite struct GitHookPathTests {
    private let launchdPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// A home folder with `uv` in `~/.local/bin`, an rc file that puts it on the `PATH`, and a
    /// repository whose `post-checkout` hook calls it.
    private struct Machine {
        let home: String
        let repository: String
        let shell: FakeShell

        init() throws {
            let root = TestScratch.root.appendingPathComponent("shellforge-home-\(UUID().uuidString)").path
            home = root
            let bin = "\(root)/.local/bin"
            try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
            try Self.executable("\(bin)/uv", "#!/bin/sh\necho uv ran in the hook\n")
            shell = try FakeShell("export PATH=\"$HOME/.local/bin:$PATH\"")

            repository = "\(root)/repo"
            try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
            let env = ["PATH": "/usr/bin:/bin", "HOME": root]
            for args in [["init", "-q", "-b", "main"],
                         ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "first"]] {
                let out = try ChildProcess.run("/usr/bin/git", ["-C", repository] + args, environment: env, timeout: 60)
                guard out.status == 0 else { throw SetupFailed(message: out.stderr) }
            }
            try Self.executable("\(repository)/.git/hooks/post-checkout", "#!/bin/sh\nset -e\nuv\n")
        }

        static func executable(_ path: String, _ text: String) throws {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
    }

    private struct SetupFailed: Error { let message: String }

    @Test func underLaunchdsPATHTheHookCannotFindUv() throws {
        let machine = try Machine()
        let out = try ChildProcess.run("/usr/bin/git", ["-C", machine.repository, "worktree", "add", "-q", "-b", "task", "../task"],
                                       environment: ["PATH": launchdPATH, "HOME": machine.home], timeout: 60)
        #expect(out.status != 0)
        #expect(out.stderr.contains("uv"))
    }

    @Test func throughTheLauncherTheHookFindsUv() throws {
        let machine = try Machine()
        let inherited = ["PATH": launchdPATH, "HOME": machine.home]
        let launcher = CommandLauncher { LoginEnvironment.resolve(shell: machine.shell.path, inherited: inherited) }
        let out = try launcher.run("git", ["-C", machine.repository, "worktree", "add", "-q", "-b", "task", "../task"])
        #expect(out.status == 0, "git said: \(out.stderr)")
        #expect((out.stdout + out.stderr).contains("uv ran in the hook"))
    }
}
