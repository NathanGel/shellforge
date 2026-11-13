import Foundation

/// What a repository ignores, as git listed it once: its ignored folders (`node_modules`, `.build`,
/// `dist`) and ignored files. A change under one of them cannot change what the Files or Git panel
/// shows, so a build that writes thousands of files there runs no git. Listed again when an ignore
/// rule changes (`changesRules`).
public struct IgnoredPaths: Equatable, Sendable {
    /// Paths relative to the repository's folder, folders without their trailing "/".
    public private(set) var entries: Set<String>

    public init(_ entries: Set<String> = []) { self.entries = entries }

    /// Nothing ignored: a folder that is not a repository, or a listing that failed.
    public static let none = IgnoredPaths()

    /// git's list for the repository at `path`: `--directory` names an ignored folder once rather
    /// than every file in it. The read is an automatic one, so the repository's fsmonitor and hooks
    /// run nothing. Nothing when git fails.
    public static func read(_ path: String, launcher: CommandLauncher) -> IgnoredPaths {
        let args = ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]
        guard let out = try? launcher.run("git", AutomaticGitRead.arguments(args, in: path), extra: ["LC_ALL": "C"], timeout: 30),
              out.status == 0, !out.timedOut else { return .none }
        return IgnoredPaths(Set(out.stdout.split(separator: "\0").map { entry in
            entry.hasSuffix("/") ? String(entry.dropLast()) : String(entry)
        }))
    }

    /// Whether `relative` is an ignored path or lies under an ignored folder.
    public func covers(_ relative: String) -> Bool {
        guard !entries.isEmpty, !relative.isEmpty else { return false }
        var prefix = ""
        for part in relative.split(separator: "/") {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            if entries.contains(prefix) { return true }
        }
        return false
    }

    /// What of a watcher's batch counts: nil when every change is ignored. An empty batch (the
    /// stream could not say what changed) counts as it is.
    public func relevant(_ changes: [String]) -> [String]? {
        guard !changes.isEmpty else { return changes }
        let kept = changes.filter { !covers($0) }
        return kept.isEmpty ? nil : kept
    }

    /// Whether a change at `relative` can change what is ignored: a `.gitignore` anywhere, or the
    /// repository's own `.git/info/exclude`.
    public static func changesRules(_ relative: String) -> Bool {
        relative == ".git/info/exclude" || relative == ".gitignore" || relative.hasSuffix("/.gitignore")
    }
}
