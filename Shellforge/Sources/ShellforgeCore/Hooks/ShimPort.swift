// Ported from AiTerm (app/Sources/AiTermCore/Hooks/ShimPort.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The port the status-line shims post to. A shim runs from the app bundle on every tick of its
/// agent's status line, so the port cannot be written into it: the drivers that install a shim
/// record the port in a small file (`ShellforgePaths.hookPortURL`) that the shim reads with a shell
/// builtin. A shim with no port recorded posts nothing.
public enum ShimPort {
    /// Whether the file says `port` exactly as `record` writes it, which a driver's probe asks: a
    /// shim reading another port, or none, posts to nothing, however current the agent's own
    /// config is — and one reading anything but a port's digits refuses it, so any other content
    /// is no port recorded either, for Repair to write again.
    public static func isRecorded(_ port: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        (try? Data(contentsOf: ShellforgePaths.hookPortURL(home: home))) == contents(port)
    }

    /// The file's bytes for `port`: its digits and a newline.
    private static func contents(_ port: Int) -> Data { Data("\(port)\n".utf8) }

    /// Writes `port` for the shims, unless it is there already. The support folder is made if it is
    /// missing, never migrated: renaming the user's data is launch's job.
    public static func record(_ port: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        guard !isRecorded(port, home: home) else { return }
        let url = ShellforgePaths.hookPortURL(home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents(port).write(to: url, options: .atomic)
    }
}
