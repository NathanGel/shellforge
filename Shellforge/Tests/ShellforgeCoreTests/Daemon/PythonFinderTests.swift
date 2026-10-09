import Foundation
import Testing
@testable import ShellforgeCore

/// Shellforge runs its daemon with a Python 3.11 or newer found on the login shell's PATH.
@Suite struct PythonFinderTests {
    /// A folder of fake interpreters, each answering the version check with `answer`.
    private func folder(_ pythons: [String: String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sf-py-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, answer) in pythons {
            let path = "\(dir)/\(name)"
            try "#!/bin/sh\necho \(answer)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return dir
    }

    private func launcher(_ path: String) -> CommandLauncher {
        CommandLauncher { ResolvedEnvironment(variables: ["PATH": "\(path):/usr/bin:/bin"], source: .loginShell("/bin/zsh")) }
    }

    @Test func python3IsTakenWhenItIsNewEnough() throws {
        let dir = try folder(["python3": "True"])
        #expect(PythonFinder.find(launcher: launcher(dir)) == "\(dir)/python3")
    }

    @Test func anOldPython3IsPassedOverForANewerVersionedOne() throws {
        let dir = try folder(["python3": "False", "python3.11": "True"])
        #expect(PythonFinder.find(launcher: launcher(dir)) == "\(dir)/python3.11")
    }

    @Test func withoutANewEnoughPythonThereIsNone() throws {
        let dir = try folder(["python3": "False"])
        let bare = CommandLauncher { ResolvedEnvironment(variables: ["PATH": dir], source: .loginShell("/bin/zsh")) }
        #expect(PythonFinder.find(launcher: bare) == nil)
    }
}
