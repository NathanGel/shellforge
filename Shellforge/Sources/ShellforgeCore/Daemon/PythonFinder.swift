import Foundation

/// The Python Shellforge runs its daemon with: 3.11 or newer, found as a terminal would find it —
/// on the login shell's `PATH` — and run through the launcher like every other child.
public enum PythonFinder {
    /// Asked in this order; `python3` first, as the one a person most likely means.
    static let candidates = ["python3", "python3.14", "python3.13", "python3.12", "python3.11"]

    /// The first candidate on the `PATH` that says it is 3.11 or newer, or nil.
    public static func find(launcher: CommandLauncher) -> String? {
        for name in candidates {
            guard let path = launcher.locate(name),
                  let out = try? launcher.run(path, ["-c", "import sys; print(sys.version_info >= (3, 11))"], timeout: 10),
                  out.status == 0, out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "True" else { continue }
            return path
        }
        return nil
    }
}
