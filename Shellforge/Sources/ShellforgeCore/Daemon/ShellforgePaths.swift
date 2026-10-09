import Foundation

/// Where Shellforge keeps what its daemon needs: its own folder, socket, log and hook port, apart
/// from AiTerm's so both can run on one Mac (`shellforged`'s `support_dir()` and `DEFAULT_HOOK_PORT`).
public enum ShellforgePaths {
    public static var supportDirectory: URL { supportDirectory(home: FileManager.default.homeDirectoryForCurrentUser) }

    /// The same folder under `home`, for code that writes the user's files and tests that give it a
    /// scratch home.
    public static func supportDirectory(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Shellforge", isDirectory: true)
    }

    /// The port the status-line shims post to (`ShimPort`); they read it with a shell builtin.
    public static func hookPortURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("hook-port")
    }

    /// The user's own Claude Code status line, which Shellforge's shim runs after posting.
    public static func statusLineOriginalURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("statusline-original.cmd")
    }

    /// The user's own Grok Build status line, which Shellforge's Grok shim runs after posting.
    public static func grokStatusLineOriginalURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        supportDirectory(home: home).appendingPathComponent("grok-statusline-original.cmd")
    }

    public static var socketPath: String { supportDirectory.appendingPathComponent("shellforged.sock").path }
    public static var daemonLogURL: URL { supportDirectory.appendingPathComponent("shellforged.log") }
    public static let hookPort = 47831
}
