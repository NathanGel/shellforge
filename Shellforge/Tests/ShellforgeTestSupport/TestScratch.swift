import Foundation
import ShellforgeCore

/// Where tests write: one folder per test run, made on first use and removed when the process exits
/// — at exit rather than per test, since a folder is often handed to an object that outlives the
/// test's own scope. Nothing a test makes is left in the temporary folder.
public enum TestScratch {
    public static let root: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        made.withLock { $0 = root }
        atexit { TestScratch.remove() }
        return root
    }()

    private static let made = Locked<URL?>(nil)

    private static func remove() {
        guard let root = made.withLock({ $0 }) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}
