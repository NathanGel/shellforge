import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// Shellforge runs its daemon with a Python 3.11 or newer found on the login shell's PATH.
@Suite struct PythonFinderTests {
    /// A folder of fake interpreters, each answering the version check with `answer`'s lines; `$0`
    /// in an answer is the fake's own path, as `sys.executable` names a real interpreter's.
    private func folder(_ pythons: [String: String]) throws -> String {
        let dir = TestScratch.root.appendingPathComponent("sf-py-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, answer) in pythons {
            let path = "\(dir)/\(name)"
            try "#!/bin/sh\nprintf '%s\\n' \(answer)\n".write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        }
        return dir
    }

    private func launcher(_ path: String) -> CommandLauncher {
        CommandLauncher { ResolvedEnvironment(variables: ["PATH": "\(path):/usr/bin:/bin"], source: .loginShell("/bin/zsh")) }
    }

    @Test func python3IsTakenWhenItIsNewEnough() throws {
        let dir = try folder(["python3": "True \"$0\""])
        #expect(PythonFinder.find(launcher: launcher(dir)) == "\(dir)/python3")
    }

    @Test func anOldPython3IsPassedOverForANewerVersionedOne() throws {
        let dir = try folder(["python3": "False \"$0\"", "python3.11": "True \"$0\""])
        #expect(PythonFinder.find(launcher: launcher(dir)) == "\(dir)/python3.11")
    }

    @Test func withoutANewEnoughPythonThereIsNone() throws {
        let dir = try folder(["python3": "False \"$0\""])
        let bare = CommandLauncher { ResolvedEnvironment(variables: ["PATH": dir], source: .loginShell("/bin/zsh")) }
        #expect(PythonFinder.find(launcher: bare) == nil)
    }

    /// A version-manager shim is checked in the login environment but launched without it, so the
    /// finder hands back the interpreter the shim ran, never the shim; a note the shim prints first
    /// is not the answer.
    @Test func aShimGivesWayToTheInterpreterItRan() throws {
        let real = try folder(["python3.12": "True \"$0\""])
        let shims = try folder(["python3": "'pyenv: using 3.12' True \(real)/python3.12"])
        #expect(PythonFinder.find(launcher: launcher(shims)) == "\(real)/python3.12")
    }

    @Test func anAnswerWithoutAnInterpreterPathIsPassedOver() throws {
        let dir = try folder(["python3": "True", "python3.11": "True \"$0\""])
        #expect(PythonFinder.find(launcher: launcher(dir)) == "\(dir)/python3.11")
    }
}
