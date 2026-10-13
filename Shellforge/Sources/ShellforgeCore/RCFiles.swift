import Foundation

/// The files the login shell reads its environment from, watched by their modification dates, so
/// a tool installed and put on PATH is found without a relaunch:
/// - zsh: `.zshenv`, `.zprofile`, `.zshrc`, in `$ZDOTDIR` or the home folder;
/// - bash: `.bash_profile`, `.bash_login`, `.profile`, `.bashrc`;
/// - fish: `~/.config/fish/config.fish`;
/// - any other: `.profile`;
/// - and, for every shell, `/etc/paths`, `/etc/paths.d` and each file in it, where installers add
///   their folders.
///
/// A file created or deleted counts as a change; a linked file is judged by its target. The shell
/// and `ZDOTDIR` are read at each check, from the environment Shellforge uses.
public struct RCFiles: Sendable {
    private let home: URL, etc: URL
    private let environment: @Sendable () -> [String: String]
    private var last: [String: Date]?

    public init(home: URL, etc: URL = URL(fileURLWithPath: "/etc"), environment: @escaping @Sendable () -> [String: String]) {
        self.home = home
        self.etc = etc
        self.environment = environment
    }

    /// The files `shell` reads at login, then the system's PATH files.
    public static func watched(home: URL, etc: URL, shell: String, zdotdir: String?) -> [URL] {
        let own: [URL]
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            let folder = zdotdir.map { URL(fileURLWithPath: $0) } ?? home
            own = [".zshenv", ".zprofile", ".zshrc"].map { folder.appendingPathComponent($0) }
        case "bash":
            own = [".bash_profile", ".bash_login", ".profile", ".bashrc"].map { home.appendingPathComponent($0) }
        case "fish":
            own = [home.appendingPathComponent(".config/fish/config.fish")]
        default:
            own = [home.appendingPathComponent(".profile")]
        }
        return own + [etc.appendingPathComponent("paths"), etc.appendingPathComponent("paths.d")]
    }

    /// Whether any of them changed since the last call; the first call only looks.
    public mutating func changed() -> Bool {
        let variables = environment()
        var files = Self.watched(home: home, etc: etc, shell: variables["SHELL"] ?? "/bin/zsh", zdotdir: variables["ZDOTDIR"])
        // Each file in /etc/paths.d too: one edited in place changes its own date, not the folder's.
        let pathsD = etc.appendingPathComponent("paths.d")
        files += ((try? FileManager.default.contentsOfDirectory(at: pathsD, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path < $1.path }
        var now: [String: Date] = [:]
        for file in files {
            // Through a link to its target: a dotfile manager's ~/.zshrc is a link, and the edit is there.
            let target = file.resolvingSymlinksInPath().path
            if let date = (try? FileManager.default.attributesOfItem(atPath: target))?[.modificationDate] as? Date {
                now[file.path] = date
            }
        }
        defer { last = now }
        guard let last else { return false }
        return now != last
    }
}
