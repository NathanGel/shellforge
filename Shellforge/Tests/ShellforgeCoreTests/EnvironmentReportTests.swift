import Foundation
import Testing
@testable import ShellforgeCore

/// What Settings › Core shows of the environment Shellforge starts things in, and how a changed rc
/// file is noticed. No login shell runs and no real home is read: launchers are scripted, homes are
/// temporary folders.
@Suite struct EnvironmentReportTests {
    private func folder(_ name: String = "env") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tool(_ name: String, in folder: URL) throws {
        let path = folder.appendingPathComponent(name).path
        try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    @Test func theReportSaysTheShellPathAndTools() throws {
        let bin = try folder("bin")
        try tool("git", in: bin)
        try tool("ssh", in: bin)
        let read = Date(timeIntervalSince1970: 1_000)
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "\(bin.path):/nowhere"], source: .loginShell("/bin/zsh")) },
                                       clock: { read })
        let report = EnvironmentReport.make(launcher: launcher, agents: [])
        #expect(report.shell == "/bin/zsh" && report.fallbackReason == nil)
        #expect(report.readAt == read)
        #expect(report.path == [bin.path, "/nowhere"])
        #expect(report.tools.map(\.name) == ["git", "uv", "python3", "node", "ssh"])
        #expect(report.tools.first { $0.name == "git" }?.path == bin.appendingPathComponent("git").path)
        #expect(report.tools.first { $0.name == "uv" }?.path == nil)
    }

    @Test func aFallbackSaysWhy() {
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .fallback("/bin/zsh did not answer within 15 s")) })
        let report = EnvironmentReport.make(launcher: launcher, agents: [])
        #expect(report.shell == nil && report.fallbackReason == "/bin/zsh did not answer within 15 s")
    }

    @Test func aToolIsShownWhereItWasFound() throws {
        let real = try folder("real"), bin = try folder("bin")
        try tool("node", in: real)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("node").path,
                                                   withDestinationPath: real.appendingPathComponent("node").path)
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": bin.path], source: .loginShell("/bin/zsh")) })
        #expect(EnvironmentReport.make(launcher: launcher, agents: []).tools.first { $0.name == "node" }?.path
                == bin.appendingPathComponent("node").path)
    }

    @Test func eachAgentCommandOnce() {
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/nowhere"], source: .loginShell("/bin/zsh")) })
        var twin = AgentPresets.claude
        twin.id = "claude-2"
        let report = EnvironmentReport.make(launcher: launcher, agents: [AgentPresets.claude, twin, AgentPresets.codex])
        #expect(report.tools.map(\.name) == ["git", "uv", "python3", "node", "ssh", "claude", "codex"])
    }

    @Test func aReportReadsTheEnvironmentOnceWhateverIsMissing() {
        let reads = Locked(0)
        let launcher = CommandLauncher(resolve: {
            reads.withLock { $0 += 1 }
            return ResolvedEnvironment(variables: ["PATH": "/nowhere"], source: .loginShell("/bin/zsh"))
        })
        _ = EnvironmentReport.make(launcher: launcher, agents: [AgentPresets.claude])
        #expect(reads.withLock { $0 } == 1, "six misses, one read: a report must not run a login shell per miss")
    }

    @Test func notFoundPointsAtSettings() {
        let error = CommandNotFound(name: "uv", searchedPath: "/usr/bin", source: .loginShell("/bin/zsh"))
        #expect(String(describing: error).hasSuffix(" Settings › Core shows the environment Shellforge uses."))
    }

    @Test func theFirstLookIsNoChange() throws {
        let home = try folder("home")
        try "export A=1\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        var files = RCFiles(home: home)
        let changed1 = files.changed()
        #expect(!changed1)
        let changed2 = files.changed()
        #expect(!changed2)
    }

    @Test func anEditedRCFileIsAChange() throws {
        let home = try folder("home")
        let rc = home.appendingPathComponent(".zprofile")
        try "export A=1\n".write(to: rc, atomically: true, encoding: .utf8)
        var files = RCFiles(home: home)
        _ = files.changed()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: rc.path)
        let changed3 = files.changed()
        #expect(changed3)
        let changed4 = files.changed()
        #expect(!changed4, "once per change")
    }

    /// A dotfile manager (stow, chezmoi, yadm) makes `~/.zshrc` a link: the edited file is its target.
    @Test func anEditedLinkedRCFileIsAChange() throws {
        let home = try folder("home"), dotfiles = try folder("dotfiles")
        let target = dotfiles.appendingPathComponent("zshrc")
        try "export A=1\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".zshrc").path, withDestinationPath: target.path)
        var files = RCFiles(home: home)
        _ = files.changed()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: target.path)
        let changed = files.changed()
        #expect(changed)
    }

    @Test func aCreatedOrDeletedFileIsAChange() throws {
        let home = try folder("home")
        var files = RCFiles(home: home)
        _ = files.changed()
        let rc = home.appendingPathComponent(".zshenv")
        try "export A=1\n".write(to: rc, atomically: true, encoding: .utf8)
        let changed5 = files.changed()
        #expect(changed5)
        try FileManager.default.removeItem(at: rc)
        let changed6 = files.changed()
        #expect(changed6)
    }

    /// Two reloads at once — Settings' Reload and a changed rc file — the later one's environment
    /// stays, whichever finishes first.
    @Test func theLatestReloadWinsWhicheverFinishesFirst() async throws {
        let first = DispatchSemaphore(value: 0)
        let calls = Locked(0)
        let launcher = CommandLauncher(resolve: {
            let n = calls.withLock { (count: inout Int) -> Int in count += 1; return count }
            if n == 1 { first.wait() }  // the first reload is slow
            return ResolvedEnvironment(variables: ["PATH": "/read-\(n)"], source: .loginShell("/bin/zsh"))
        })
        let slow = Thread { launcher.reload() }
        slow.start()
        while calls.withLock({ $0 }) < 1 { try await Task.sleep(for: .milliseconds(5)) }
        launcher.reload()               // the second, started later, finishes first
        first.signal()
        while !slow.isFinished { try await Task.sleep(for: .milliseconds(5)) }
        #expect(launcher.environment.variables["PATH"] == "/read-2")
    }
}
