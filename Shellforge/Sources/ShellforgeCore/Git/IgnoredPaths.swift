import Foundation

/// What a repository ignores, as git listed it once: its ignored folders (`node_modules`, `.build`,
/// `dist`) and ignored files. A change under one of them cannot change what the Files or Git panel
/// shows, so a build that writes thousands of files there runs no git. Listed again when an ignore
/// rule or the index changes (`changesRules`), and now and then when a change falls outside the
/// list, so a folder that appears after it was read (a first build) is learnt.
public struct IgnoredPaths: Equatable, Sendable {
    /// Paths relative to the repository's folder, folders without their trailing "/".
    public private(set) var entries: Set<String>
    /// Whether an ignore rule negates (`!dist/keep`): git then lists `dist/` whole while a file it
    /// would show can still appear in it, so only the listed paths themselves are covered, never
    /// what is under a listed folder.
    public private(set) var negates: Bool

    public init(_ entries: Set<String> = [], negates: Bool = false) {
        self.entries = entries
        self.negates = negates
    }

    /// Nothing ignored: a folder that is not a repository, or a listing that failed.
    public static let none = IgnoredPaths()

    /// git's list for the repository at `path`: `--directory` names an ignored folder once rather
    /// than every file in it. It also names a folder that is not ignored but holds only ignored
    /// files (`logs/` for `logs/a.log` under `*.log`), so each folder is asked of `check-ignore`
    /// and kept only when git says the folder itself is ignored. Then whether any rule git reads
    /// negates: the `.gitignore` files git does not ignore, the repository's `info/exclude` and the
    /// global excludes file. The reads are automatic ones, so the repository's fsmonitor and hooks
    /// run nothing. Nothing when git fails.
    public static func read(_ path: String, launcher: CommandLauncher) -> IgnoredPaths {
        let args = ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]
        guard let listed = git(args, in: path, launcher: launcher) else { return .none }
        let all = listed.split(separator: "\0").map(String.init)
        var entries = Set(all.filter { !$0.hasSuffix("/") })
        let folders = all.filter { $0.hasSuffix("/") }
        if !folders.isEmpty {
            guard let ignored = ignoredFolders(folders, in: path, launcher: launcher) else { return .none }
            entries.formUnion(ignored)
        }
        return IgnoredPaths(entries, negates: entries.isEmpty ? false : negates(path, launcher: launcher))
    }

    /// Of `folders` (each with its trailing "/"), those git ignores themselves, without the "/".
    /// nil when git fails. check-ignore exits 1 when it matches nothing, which is an answer.
    private static func ignoredFolders(_ folders: [String], in path: String, launcher: CommandLauncher) -> Set<String>? {
        let input = Data(folders.joined(separator: "\0").appending("\0").utf8)
        guard let out = try? launcher.run("git", AutomaticGitRead.arguments(["check-ignore", "-z", "--stdin"], in: path),
                                          extra: ["LC_ALL": "C"], input: input, timeout: 30),
              out.status == 0 || out.status == 1, !out.timedOut else { return nil }
        return Set(out.stdout.split(separator: "\0").compactMap { entry in
            entry.hasSuffix("/") ? String(entry.dropLast()) : nil
        })
    }

    /// Whether a rule git reads for the repository starts with `!`. Unsure (git failed) is yes.
    private static func negates(_ path: String, launcher: CommandLauncher) -> Bool {
        let gitignores = ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", ":(glob)**/.gitignore"]
        guard let listed = git(gitignores, in: path, launcher: launcher),
              let exclude = git(["rev-parse", "--git-path", "info/exclude"], in: path, launcher: launcher) else { return true }
        var sources = listed.split(separator: "\0").map { (path as NSString).appendingPathComponent(String($0)) }
        let excludePath = exclude.trimmingCharacters(in: .newlines)
        sources.append(excludePath.hasPrefix("/") ? excludePath : (path as NSString).appendingPathComponent(excludePath))
        sources.append(globalExcludes(path, launcher: launcher))
        return sources.contains { source in
            guard let text = try? String(contentsOfFile: source, encoding: .utf8) else { return false }
            return text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("!") }
        }
    }

    /// `core.excludesFile`, else git's default: `$XDG_CONFIG_HOME/git/ignore` or `~/.config/git/ignore`.
    private static func globalExcludes(_ path: String, launcher: CommandLauncher) -> String {
        if let set = git(["config", "--path", "--get", "core.excludesFile"], in: path, launcher: launcher)?
            .trimmingCharacters(in: .newlines), !set.isEmpty {
            return set
        }
        let variables = launcher.environment.variables
        if let xdg = variables["XDG_CONFIG_HOME"], !xdg.isEmpty { return xdg + "/git/ignore" }
        return (variables["HOME"] ?? NSHomeDirectory()) + "/.config/git/ignore"
    }

    private static func git(_ args: [String], in path: String, launcher: CommandLauncher) -> String? {
        guard let out = try? launcher.run("git", AutomaticGitRead.arguments(args, in: path), extra: ["LC_ALL": "C"], timeout: 30),
              out.status == 0, !out.timedOut else { return nil }
        return out.stdout
    }

    /// Whether `relative` is an ignored path or lies under an ignored folder (only the path itself
    /// while a rule negates).
    public func covers(_ relative: String) -> Bool {
        guard !entries.isEmpty, !relative.isEmpty else { return false }
        if negates { return entries.contains(relative) }
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

    /// Whether a change at `relative` can change what is ignored: a `.gitignore` git reads (not one
    /// inside an ignored folder, which tools such as a venv or a test cache write and git never
    /// reads), the repository's own `.git/info/exclude`, or its index (a file added with
    /// `git add -f` inside an ignored folder is tracked, and listed no more).
    public func changesRules(_ relative: String) -> Bool {
        if relative == ".git/info/exclude" || relative == ".git/index" { return true }
        guard relative == ".gitignore" || relative.hasSuffix("/.gitignore") else { return false }
        return !covers((relative as NSString).deletingLastPathComponent)
    }

    /// Whether `relative` is the repository's own git folder or in it: never listed, never ignored.
    public static func isGitFolder(_ relative: String) -> Bool {
        relative == ".git" || relative.hasPrefix(".git/")
    }
}
