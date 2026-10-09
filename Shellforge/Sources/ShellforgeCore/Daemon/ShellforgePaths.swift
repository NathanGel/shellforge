import Foundation

/// Where Shellforge keeps what its daemon needs: its own folder, socket, log and hook port, apart
/// from AiTerm's so both can run on one Mac (`shellforged`'s `support_dir()` and `DEFAULT_HOOK_PORT`).
public enum ShellforgePaths {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellforge", isDirectory: true)
    }

    public static var socketPath: String { supportDirectory.appendingPathComponent("shellforged.sock").path }
    public static var daemonLogURL: URL { supportDirectory.appendingPathComponent("shellforged.log") }
    public static let hookPort = 47831
}
