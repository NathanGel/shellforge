import Foundation

/// The Python Shellforge runs its daemon with: 3.11 or newer, found as a terminal would find it —
/// on the login shell's `PATH` — and run through the launcher like every other child.
public enum PythonFinder {
    /// Asked in this order; `python3` first, as the one a person most likely means.
    static let candidates = ["python3", "python3.14", "python3.13", "python3.12", "python3.11"]

    /// The interpreter behind the first candidate on the `PATH` that says it is 3.11 or newer, or
    /// nil. The answer is `sys.executable`, not the candidate: a version-manager shim (pyenv, asdf)
    /// is checked here in the login environment but would be launched without it, and could pick
    /// another Python or none. Blocks for the login shell and each check; call it off the main thread.
    public static func find(launcher: CommandLauncher) -> String? {
        for name in candidates {
            guard let path = launcher.locate(name),
                  let out = try? launcher.run(path, ["-c", "import sys; print(sys.version_info >= (3, 11)); print(sys.executable)"], timeout: 10),
                  out.status == 0, let interpreter = interpreter(answering: out.stdout) else { continue }
            return interpreter
        }
        return nil
    }

    /// The last two lines are the check's: "True", then an absolute path that can be run. Anything
    /// a shim or a `.pth` hook printed before them is not the answer.
    static func interpreter(answering stdout: String) -> String? {
        let lines = stdout.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, lines[lines.count - 2] == "True", let path = lines.last, path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
