// Ported from AiTerm (app/Tests/AiTermTestSupport/ScratchDefaults.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// A `UserDefaults` domain of a test's own, so it starts from nothing and never reads or writes the
/// developer's. Its name is a path in a temporary folder, which cfprefsd takes as the file to keep
/// the domain in: a suite named like an app instead lands in `~/Library/Preferences`, and cfprefsd
/// writes it back there, if only as an empty dictionary, even after `removePersistentDomain` and a
/// deleted file. The folder goes when the test process exits — at exit rather than per test, since a
/// domain is often handed to an object that outlives the test's own scope.
public enum ScratchDefaults {
    public static func make() -> UserDefaults {
        let path = folder.appendingPathComponent(UUID().uuidString).path
        return UserDefaults(suiteName: path)!
    }

    /// Made, and its removal registered, on first use.
    private static let folder: URL = {
        let folder = TestScratch.root.appendingPathComponent("defaults-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        created.withLock { $0 = folder }
        atexit { ScratchDefaults.removeFolder() }
        return folder
    }()
    private static let created = Locked<URL?>(nil)

    private static func removeFolder() {
        guard let folder = created.withLock({ $0 }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
