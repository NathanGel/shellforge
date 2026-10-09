// Ported from AiTerm (app/Sources/AiTermCore/Git/BranchNaming.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The names Shellforge gives, as AiTerm gives them: what it creates: a task's branch from its ticket and title, and the
/// worktree directory a task's or review's branch is checked out in.
public enum BranchNaming {
    /// `text` lowercased to ASCII letters and digits, every run of anything else one `-`, at most
    /// 48 characters.
    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = "", lastDash = true
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.count > 48 { out = String(out.prefix(48)); while out.hasSuffix("-") { out.removeLast() } }
        return out
    }

    /// The part of a task branch after its type: the ticket key, then the slugged summary.
    public static func branchSlug(key: String?, summary: String) -> String {
        [key?.lowercased(), slug(summary)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// The worktree directory for `branch`, less its type: `feat/login` works in `.worktrees/login`.
    public static func worktreeSlug(branch: String) -> String {
        let withoutPrefix = branch.split(separator: "/").dropFirst().joined(separator: "-")
        var slug = Self.slug(withoutPrefix.isEmpty ? branch : withoutPrefix)
        // `slug` keeps ASCII letters and digits only, so a branch like `feat/日本語` or `feat/--` can
        // slug to nothing at all — and an empty slug would make the worktree path the `.worktrees`
        // directory itself, which git would then be asked to create a checkout in. Fall back to the
        // whole branch name, then to a random but valid directory name.
        if slug.isEmpty { slug = Self.slug(branch) }
        if slug.isEmpty { slug = "task-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased() }
        return slug
    }

    /// A review's worktree directory, prefixed so a review and a task on related branches cannot
    /// collide on a path and so the directory says which it is.
    public static func reviewSlug(branch: String) -> String { "review-" + worktreeSlug(branch: branch) }

    /// `slug`, else the first of `slug-2`, `slug-3`… that is not already in `repo`'s worktree
    /// directory: dropping the type makes `feat/login` and `fix/login` want the same one. Create
    /// and the sheets' preview both ask this, so the directory named is the one made.
    public static func unused(_ slug: String, in repo: String) -> String {
        let directory = repo + "/.worktrees/"
        var candidate = slug, n = 1
        while FileManager.default.fileExists(atPath: directory + candidate) { n += 1; candidate = "\(slug)-\(n)" }
        return candidate
    }

    /// Whether git takes `name` as a branch name: git, through the login shell's environment.
    public static func isValid(_ name: String, launcher: CommandLauncher) -> Bool {
        (try? launcher.run("git", ["check-ref-format", "--branch", name]))?.status == 0
    }
}
