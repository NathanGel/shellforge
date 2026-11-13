import Foundation

/// One changed file, as `git status` reports it.
public struct GitChange: Equatable, Sendable, Identifiable {
    public enum Letter: String, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R", copied = "C"
        case untracked = "U", typeChanged = "T", conflicted = "!"
    }

    public var path: String
    /// Where a renamed or copied file came from.
    public var originalPath: String?
    public var letter: Letter
    public var id: String

    public init(path: String, originalPath: String? = nil, letter: Letter) {
        self.path = path
        self.originalPath = originalPath
        self.letter = letter
        self.id = path
    }
}

/// A repository's branch and changes: what the Git panel shows. Untracked files are among the
/// unstaged changes; task worktrees, under `.worktrees/`, are never listed.
public struct GitStatus: Equatable, Sendable {
    public enum Head: Equatable, Sendable {
        case branch(String)
        /// A branch with no commit yet.
        case unborn(String)
        case detached(sha: String)
    }

    public var head: Head = .branch("")
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var staged: [GitChange] = []
    public var unstaged: [GitChange] = []
    public var conflicted: [GitChange] = []

    public var hasChanges: Bool { !staged.isEmpty || !unstaged.isEmpty || !conflicted.isEmpty }

    static let gitTimeout: TimeInterval = 30
    static let worktrees = ".worktrees/"
    static let shortSHALength = 7

    /// `git status --porcelain=v2 --branch -z --untracked-files=all`, read. `-z` quotes no path,
    /// so odd names survive; `LC_ALL=C` keeps git's messages in English. `GIT_OPTIONAL_LOCKS=0`
    /// stops status from rewriting the index, which the Git panel watches: a read must not cause
    /// the event that reads again.
    public static func read(_ path: String, launcher: CommandLauncher) throws -> GitStatus {
        let args = AutomaticGitRead.arguments(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: path, launcher: launcher)
        let out: ChildOutput
        do {
            out = try launcher.run("git", args, extra: ["LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0"], timeout: gitTimeout)
        } catch {
            throw GitFailure(message: error.localizedDescription)
        }
        if out.timedOut { throw GitFailure(message: "git timed out") }
        guard out.status == 0 else {
            let line = out.stderr.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
            throw GitFailure(message: line ?? "git failed")
        }
        return parse(out.stdout)
    }

    /// Parses porcelain v2 output separated by NUL. A rename or copy entry is followed by one more
    /// NUL-separated field: the original path.
    public static func parse(_ porcelainV2: String) -> GitStatus {
        var status = GitStatus()
        var branchName = "", oid = ""
        let fields = porcelainV2.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        func add(_ change: GitChange, to keyPath: WritableKeyPath<GitStatus, [GitChange]>) {
            guard !change.path.hasPrefix(worktrees) else { return }
            status[keyPath: keyPath].append(change)
        }
        while index < fields.count {
            let entry = fields[index]
            index += 1
            if entry.hasPrefix("# ") {
                let parts = entry.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.oid": oid = parts[1]
                case "branch.head": branchName = parts[1]
                case "branch.upstream": status.upstream = parts[1]
                case "branch.ab":
                    for count in parts[1].split(separator: " ") {
                        guard let number = Int(count.dropFirst()) else { continue }
                        if count.hasPrefix("+") { status.ahead = number } else { status.behind = number }
                    }
                default: break
                }
            } else if entry.hasPrefix("? ") {
                add(GitChange(path: String(entry.dropFirst(2)), letter: .untracked), to: \.unstaged)
            } else if entry.hasPrefix("1 ") || entry.hasPrefix("2 ") || entry.hasPrefix("u ") {
                // "1 XY sub mH mI mW hH hI path", "2 XY sub mH mI mW hH hI score path" (+ original),
                // "u XY sub m1 m2 m3 mW h1 h2 h3 path": the path, last, may hold spaces.
                let kind = entry.first!
                let leading = kind == "1" ? 8 : kind == "2" ? 9 : 10
                let parts = entry.split(separator: " ", maxSplits: leading, omittingEmptySubsequences: false).map(String.init)
                guard parts.count == leading + 1 else { continue }
                let path = parts[leading]
                if kind == "u" {
                    add(GitChange(path: path, letter: .conflicted), to: \.conflicted)
                    continue
                }
                var original: String?
                if kind == "2", index < fields.count {
                    original = fields[index]
                    index += 1
                }
                let xy = Array(parts[1])
                guard xy.count == 2 else { continue }
                if let letter = letter(xy[0]) {
                    add(GitChange(path: path, originalPath: original, letter: letter), to: \.staged)
                }
                if let letter = letter(xy[1]) {
                    add(GitChange(path: path, originalPath: original, letter: letter), to: \.unstaged)
                }
            }
        }
        if branchName == "(detached)" {
            status.head = .detached(sha: String(oid.prefix(shortSHALength)))
        } else if oid == "(initial)" {
            status.head = .unborn(branchName)
        } else {
            status.head = .branch(branchName)
        }
        return status
    }

    /// The change a status column shows; nil for "." (unchanged).
    private static func letter(_ column: Character) -> GitChange.Letter? {
        guard column != "." else { return nil }
        return GitChange.Letter(rawValue: String(column)) ?? .modified
    }
}
