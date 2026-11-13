import Foundation

/// A git read Shellforge makes on its own — a panel's refresh, a badge, a branch list, a count —
/// rather than one the person asked for. The repository's own configuration runs nothing there:
/// no `core.fsmonitor` command, no hook, and no content filter it defines. A `.git` that came in
/// an archive or on a shared drive can name any command as its fsmonitor or as a filter's `clean`,
/// and `git status` or `git diff` would run it.
///
/// Explicit Commit, Push, Pull, Switch and New Task keep the person's hooks and filters: they never
/// use this.
public enum AutomaticGitRead {
    /// git's options for such a read, placed before the subcommand.
    public static let options = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    /// `-C path`, the options, then `args`: what follows `git` for a read in `path` that runs no
    /// content filter whatever the configuration says (a ref or remote read).
    public static func arguments(_ args: [String], in path: String) -> [String] { ["-C", path] + options + args }

    /// As `arguments(_:in:)`, plus an empty `clean`, `smudge` and `process` for every filter driver
    /// the repository's own configuration defines: for a read that compares file contents
    /// (`status`, `diff`), which would otherwise run them.
    public static func arguments(_ args: [String], in path: String, launcher: CommandLauncher) -> [String] {
        ["-C", path] + options + filterOverrides(path, launcher: launcher) + args
    }

    /// The `-c` options that switch off each filter driver the repository's `.git/config` (or its
    /// worktree's config, or a file either includes) defines. Not the person's global or system
    /// drivers, which are their own (an LFS install), nor a driver set to git-lfs's own commands,
    /// which run the person's installed git-lfs. Read once per repository and kept until its
    /// config file changes.
    static func filterOverrides(_ path: String, launcher: CommandLauncher) -> [String] {
        let stamp = configStamp(path)
        if let stamp, let kept = cache.withLock({ $0[path] }), kept.stamp == stamp { return kept.overrides }
        let overrides = readOverrides(path, launcher: launcher)
        if let stamp {
            cache.withLock { cache in
                if cache.count >= 256 { cache.removeAll() }
                cache[path] = (stamp, overrides)
            }
        }
        return overrides
    }

    private static let cache = Locked<[String: (stamp: [Date?], overrides: [String])]>([:])

    /// The commands git-lfs's own install writes: they run the person's git-lfs, nothing the
    /// repository names.
    private static let lfsCommands: Set<String> = ["git-lfs clean -- %f", "git-lfs smudge -- %f", "git-lfs filter-process"]

    private static func readOverrides(_ path: String, launcher: CommandLauncher) -> [String] {
        let args = arguments(["config", "-z", "--show-scope", "--get-regexp", #"^filter\..*\.(clean|smudge|process)$"#], in: path)
        guard let out = try? launcher.run("git", args, extra: ["LC_ALL": "C"], timeout: 10), !out.timedOut else { return [] }
        // Entries are `scope\0name\nvalue\0`. Exit 1 is "none set".
        let fields = out.stdout.split(separator: "\0", omittingEmptySubsequences: false)
        var drivers: [String] = []
        var index = 0
        while index + 1 < fields.count {
            let scope = fields[index], entry = fields[index + 1]
            index += 2
            guard scope == "local" || scope == "worktree" else { continue }
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0]), value = parts.count > 1 ? String(parts[1]) : ""
            guard !lfsCommands.contains(value) else { continue }
            // filter.<driver>.<key>: the driver may itself hold dots.
            let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
            guard pieces.count >= 3 else { continue }
            let driver = pieces[1..<(pieces.count - 1)].joined(separator: ".")
            if !drivers.contains(driver) { drivers.append(driver) }
        }
        return drivers.flatMap { driver in
            ["clean", "smudge", "process"].flatMap { ["-c", "filter.\(driver).\($0)="] } + ["-c", "filter.\(driver).required=false"]
        }
    }

    /// When the repository's config files last changed: `.git/config`, or for a linked worktree
    /// its common folder's `config` and its own `config.worktree`. nil when `.git` is not where a
    /// read can find it cheaply, and the overrides are then read every time.
    private static func configStamp(_ path: String) -> [Date?]? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        let gitDir: String
        if isDirectory.boolValue {
            gitDir = dotGit
        } else {
            guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                  let line = text.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir: ") else { return nil }
            let named = String(line.dropFirst("gitdir: ".count))
            gitDir = named.hasPrefix("/") ? named : (path as NSString).appendingPathComponent(named)
        }
        var common = gitDir
        if let named = try? String(contentsOfFile: gitDir + "/commondir", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            common = named.hasPrefix("/") ? named : (gitDir as NSString).appendingPathComponent(named)
        }
        func modified(_ file: String) -> Date? {
            (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        }
        return [modified(common + "/config"), modified(gitDir + "/config.worktree")]
    }
}
