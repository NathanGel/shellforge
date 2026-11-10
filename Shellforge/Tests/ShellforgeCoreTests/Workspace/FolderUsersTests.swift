import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// Which programs hold a folder — their current directory in it — when a removal can't delete it:
/// one `lsof -F` call, read here.
@Suite struct FolderUsersTests {
    private let folder = "/Users/me/app/.worktrees/abc-42"

    /// `lsof -a -d cwd -F pcn`: a `p` line opens each process, `c` names it and `n` is its folder.
    @Test func lsofOutputIsReadForProcessesInTheFolderOrBelowIt() {
        let output = """
        p1\ncsystemd\nfcwd\nn/
        p4211\ncnode\nfcwd\nn/Users/me/app/.worktrees/abc-42
        p4230\ncnuxt\nfcwd\nn/Users/me/app/.worktrees/abc-42/apps/web
        p4300\ncvim\nfcwd\nn/Users/me/app/.worktrees/abc-42-other
        p77\ncShellforge\nfcwd\nn/Users/me/app/.worktrees/abc-42

        """
        #expect(FolderUsers.parse(output, folder: folder, excluding: 77)
                == [FolderUser(pid: 4211, name: "node"), FolderUser(pid: 4230, name: "nuxt")])
    }

    /// Lines lsof's format doesn't promise, or a process cut short, are passed over.
    @Test func garbageIsTolerated() {
        let output = "lsof: WARNING: can't stat()\n\npnotapid\ncghost\nn\(folder)\np12\nn\(folder)\nzzz\np13\ncbash\nfcwd\nn\(folder)\n"
        #expect(FolderUsers.parse(output, folder: folder, excluding: 0)
                == [FolderUser(pid: 12, name: "?"), FolderUser(pid: 13, name: "bash")])
        #expect(FolderUsers.parse("", folder: folder, excluding: 0).isEmpty)
    }

    /// A real process whose current directory is inside the folder is found, by its pid.
    @Test func aChildProcessInsideTheFolderIsFound() throws {
        let folder = TestScratch.root.appendingPathComponent("busy-\(UUID().uuidString)/apps/web")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // `ready` is written after the `cd`: once it is read, the shell's folder is the one asked about.
        child.arguments = ["-c", #"cd "$1" && echo ready && exec cat"#, "sh", folder.path]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        defer {
            child.terminate()
            try? input.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        var said = Data()
        while !String(decoding: said, as: UTF8.self).contains("ready") {
            let chunk = output.fileHandleForReading.availableData
            try #require(!chunk.isEmpty, "the shell ended before it was ready")
            said.append(chunk)
        }

        let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin"], source: .loginShell("/bin/sh")) }
        let users = FolderUsers.processes(using: folder.deletingLastPathComponent().deletingLastPathComponent().path,
                                          launcher: launcher)
        #expect(users.contains { $0.pid == child.processIdentifier }, "\(users)")
        #expect(!users.contains { $0.pid == getpid() })
    }

    /// No lsof to run: nobody found, not an error.
    @Test func aFailureFindsNobody() {
        let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/nonexistent"], source: .loginShell("/bin/sh")) }
        #expect(FolderUsers.processes(using: "/tmp", launcher: launcher, lsof: "lsof-missing").isEmpty)
    }
}
