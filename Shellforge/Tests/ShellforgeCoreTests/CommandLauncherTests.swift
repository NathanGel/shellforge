import Foundation
import Testing
@testable import ShellforgeCore

/// A folder holding one executable script, standing in for `~/.local/bin` with `uv` in it.
private struct ToolFolder {
    let path: String

    init(tool name: String, printing text: String = "ran") throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-bin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.path
        let tool = url.appendingPathComponent(name).path
        try "#!/bin/sh\necho \(text)\n".write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
    }
}

/// Answers with the given environments in turn, the last one from then on, and counts the asks.
private final class ScriptedResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [ResolvedEnvironment]
    private(set) var asked = 0

    init(_ paths: String...) {
        answers = paths.map { ResolvedEnvironment(variables: ["PATH": $0, "MARK": "login"], source: .loginShell("/bin/zsh")) }
    }

    func next() -> ResolvedEnvironment {
        lock.withLock {
            asked += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
    }
}

@Suite struct CommandLauncherTests {
    @Test func findsAToolOnTheLoginShellsPATH() throws {
        let bin = try ToolFolder(tool: "uv")
        let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "\(bin.path):/usr/bin"], source: .loginShell("/bin/zsh")) }
        #expect(launcher.locate("uv") == "\(bin.path)/uv")
    }

    @Test func aFolderOfTheSameNameIsNotATool() throws {
        let bin = try ToolFolder(tool: "other")
        try FileManager.default.createDirectory(atPath: "\(bin.path)/uv", withIntermediateDirectories: true)
        let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": bin.path], source: .loginShell("/bin/zsh")) }
        #expect(launcher.locate("uv") == nil)
    }

    @Test func theChildGetsTheLoginEnvironment() throws {
        let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin", "MARK": "login"], source: .loginShell("/bin/zsh")) }
        let output = try launcher.run("env", [])
        #expect(output.stdout.contains("MARK=login\n"))
    }

    @Test func aMissReadsTheEnvironmentAgainOnceBeforeGivingUp() throws {
        let bin = try ToolFolder(tool: "uv", printing: "uv ran")
        let resolver = ScriptedResolver("/usr/bin:/bin", "\(bin.path):/usr/bin:/bin")
        let launcher = CommandLauncher(resolve: resolver.next)
        #expect(try launcher.run("uv", []).stdout == "uv ran\n")
        #expect(resolver.asked == 2)
    }

    @Test func aToolFoundNowhereIsReportedWithThePATHSearched() throws {
        let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin"], source: .loginShell("/bin/zsh")) }
        let error = try #require(throws: CommandNotFound.self) { try launcher.run("uv", []) }
        #expect(error.name == "uv")
        #expect(error.description.contains("uv"))
        #expect(error.description.contains("/usr/bin:/bin"))
        #expect(error.description.contains("/bin/zsh"))
    }

    @Test func anAbsolutePathIsRunAsGiven() throws {
        let bin = try ToolFolder(tool: "tool", printing: "absolute")
        let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) }
        #expect(try launcher.run("\(bin.path)/tool", []).stdout == "absolute\n")
    }
}
