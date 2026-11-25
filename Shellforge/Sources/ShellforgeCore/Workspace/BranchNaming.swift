// Ported from AiTerm (app/Sources/AiTermCore/Git/BranchNaming.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// How a project names its tasks' branches.
public enum BranchFormat: String, Codable, Sendable, CaseIterable {
    /// `feat/abc-123-add-login-page`: the type, then the ticket key and the summary.
    case typeAndName
    /// `ABC-123`: the ticket key alone, for a repository whose convention that is. A task with no
    /// ticket falls back to `typeAndName`.
    case ticketKey
    /// The project's own pattern (`Project.branchPattern`), such as `{KEY}-{slug}`. A task it has
    /// nothing to say for falls back to `typeAndName`.
    case custom
}

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

/// A Custom branch-name pattern: literal text and the tokens `{type}` (feat, fix, chore), `{key}`
/// and `{KEY}` (the ticket key, lower and upper case) and `{slug}` (the summary, slugged).
public enum BranchPattern {
    /// What Type and Name gives, as a pattern.
    public static let typeAndName = "{type}/{key}-{slug}"
    /// What Ticket Key Only gives, as a pattern.
    public static let ticketKey = "{KEY}"
    public static let tokens = ["{type}", "{key}", "{KEY}", "{slug}"]
    /// The tokens that name the work; `{type}` alone names nothing.
    static let nameTokens: Set<String> = ["{key}", "{KEY}", "{slug}"]
    static let separators: Set<Character> = ["-", "_", "/", "."]

    /// What is wrong with `pattern` as a branch name, in the Custom sheet's words; nil when its
    /// branches are ones git takes. Tokens render to letters, digits and `-`, so the literal text is
    /// what can break `git check-ref-format`; New Task still asks git before it creates.
    public static func problem(_ pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "Type a pattern." }
        if let unknown = unknownToken(in: trimmed) { return "\(unknown) isn’t a token: use {type}, {key}, {KEY} or {slug}." }
        if !namesTheWork(trimmed) { return "Use {key}, {KEY} or {slug}, so each task gets its own branch." }
        return refusal(of: tokens.reduce(trimmed) { $0.replacingOccurrences(of: $1, with: "x") })
    }

    /// Why git would refuse `name` as a branch, from `git check-ref-format`'s rules; nil when it
    /// would take it.
    static func refusal(of name: String) -> String? {
        if name.contains(where: { " ~^:?*[\\".contains($0) || $0.isNewline || ($0.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false) }) || name.contains("..") || name.contains("@{") {
            return "Git doesn’t allow spaces, ~ ^ : ? * [ \\ or .. in a branch name."
        }
        if name.hasPrefix("-") || name == "@" || name.hasPrefix("/") || name.hasSuffix("/") || name.hasPrefix(".") || name.hasSuffix(".")
            || name.contains("//") || name.contains("/.") || name.split(separator: "/").contains(where: { $0.hasSuffix(".lock") }) {
            return "A branch name can’t start with - or end in .lock, start or end with / or ., or hold //."
        }
        return nil
    }

    /// The first `{…}` in `pattern` that is not one of `tokens`.
    static func unknownToken(in pattern: String) -> String? {
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { return String(rest[open...]) }
            let token = String(rest[open...close])
            if !tokens.contains(token) { return token }
            rest = rest[rest.index(after: close)...]
        }
        return nil
    }

    public static func namesTheWork(_ pattern: String) -> Bool { nameTokens.contains { pattern.contains($0) } }
    public static func hasType(_ pattern: String) -> Bool { pattern.contains("{type}") }

    /// `pattern` filled in. A token with nothing to say — no ticket, or a summary that slugs to
    /// nothing — drops with the separator after it, else the one before, so `{type}/{key}-{slug}`
    /// without a ticket is `feat/add-login-page`. Empty when no name token has anything to say, or
    /// when what is left is a branch git would refuse: either way New Task falls back to Type and Name.
    public static func render(_ pattern: String, type: BranchType, key: String?, summary: String) -> String {
        let values = ["{type}": type.rawValue, "{key}": key?.lowercased() ?? "", "{KEY}": key?.uppercased() ?? "",
                      "{slug}": BranchNaming.slug(summary)]
        var parts: [(text: String, token: String?)] = []
        var rest = Substring(pattern)
        while let ch = rest.first {
            if let token = tokens.first(where: { rest.hasPrefix($0) }) {
                parts.append((values[token] ?? "", token)); rest = rest.dropFirst(token.count)
            } else {
                if let last = parts.last, last.token == nil { parts[parts.count - 1].text.append(ch) } else { parts.append((String(ch), nil)) }
                rest = rest.dropFirst()
            }
        }
        guard parts.contains(where: { $0.token.map(nameTokens.contains) == true && !$0.text.isEmpty }) else { return "" }
        for i in parts.indices where parts[i].token != nil && parts[i].text.isEmpty {
            if i + 1 < parts.count, parts[i + 1].token == nil, let first = parts[i + 1].text.first, separators.contains(first) {
                parts[i + 1].text.removeFirst()
            } else if i > 0, parts[i - 1].token == nil, let last = parts[i - 1].text.last, separators.contains(last) {
                parts[i - 1].text.removeLast()
            }
        }
        // Dropping one separator per token can leave one at an end: `{KEY}--{slug}` without a key.
        // Only such an end is trimmed; the pattern's own text, as `_wip/`, stays.
        let emptyAt = { (part: (text: String, token: String?)?) in part?.token != nil && part?.text.isEmpty == true }
        var branch = Substring(parts.map(\.text).joined())
        if emptyAt(parts.first) { branch = branch.drop { separators.contains($0) } }
        if emptyAt(parts.last) { while let last = branch.last, separators.contains(last) { branch.removeLast() } }
        return refusal(of: String(branch)) == nil ? String(branch) : ""
    }
}
