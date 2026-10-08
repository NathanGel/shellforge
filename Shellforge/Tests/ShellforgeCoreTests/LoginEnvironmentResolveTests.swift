import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct LoginEnvironmentResolveTests {
    private let launchd = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/me"]

    @Test func takesTheEnvironmentTheLoginShellBuilds() throws {
        let shell = try FakeShell("echo 'Welcome!'\nexport PATH=/opt/homebrew/bin:/Users/me/.local/bin:$PATH\nexport SSH_AUTH_SOCK=/tmp/agent")
        let resolved = LoginEnvironment.resolve(shell: shell.path, inherited: launchd)
        #expect(resolved.source == .loginShell(shell.path))
        #expect(resolved.variables["PATH"]?.hasPrefix("/opt/homebrew/bin:/Users/me/.local/bin:") == true)
        #expect(resolved.variables["SSH_AUTH_SOCK"] == "/tmp/agent")
    }

    @Test func runsTheShellAsALoginInteractiveShell() throws {
        let shell = try FakeShell("")
        #expect(LoginEnvironment.resolve(shell: shell.path, inherited: launchd).variables["SHELL_ARGS"] == "-l -i -c")
    }

    @Test func aFailingShellFallsBackToTheUsualToolFolders() throws {
        let shell = try FakeShell("exit 3")
        let resolved = LoginEnvironment.resolve(shell: shell.path, inherited: launchd)
        guard case .fallback(let reason) = resolved.source else { Issue.record("expected a fallback"); return }
        #expect(reason.contains("exited with status 3"))
        #expect(resolved.variables["PATH"] ==
            "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/Users/me/.local/bin:/Users/me/.cargo/bin")
    }

    @Test func aShellThatHangsIsGivenUpOnAtTheDeadline() throws {
        let shell = try FakeShell("sleep 30")
        let started = Date()
        let resolved = LoginEnvironment.resolve(shell: shell.path, inherited: launchd, timeout: 0.5)
        #expect(Date().timeIntervalSince(started) < 5)
        guard case .fallback(let reason) = resolved.source else { Issue.record("expected a fallback"); return }
        #expect(reason.contains("did not answer within"))
    }
}
