import Foundation

/// What a hook entry carries to show the helper it is this user's (`HookToken`): the token itself,
/// for an entry that can only name a header's value (Claude Code's HTTP hooks, Codex's MCP server),
/// and the file it is in, for a curl command, which sends it with `-H @<file>` so the token never
/// shows in a command line. Nil where a driver builds an entry without one: what an install made
/// before hooks carried it looks like, which the launch's upgrade looks for.
struct HookAuth: Equatable, Sendable {
    let token: String
    let file: String

    init(token: String, file: String) {
        self.token = token
        self.file = file
    }

    /// The token already in `support`'s folder, for a probe, which writes nothing; nil when there
    /// is none, and an install makes it.
    static func existing(in support: ShellforgeSupport) -> HookAuth? {
        HookToken.read(in: support).map { HookAuth(token: $0, file: HookToken.url(in: support).path) }
    }

    /// The token in `support`'s folder, made when there is none, for an install.
    static func made(in support: ShellforgeSupport) throws -> HookAuth {
        HookAuth(token: try HookToken.readOrCreate(in: support), file: HookToken.url(in: support).path)
    }

    /// curl's `-H @<file>`, quoted for a shell. Double quotes, so it fits inside a TOML literal
    /// string as well (Codex's), which no single quote may: nil for a path holding one, or a line
    /// break, which no account's home holds.
    var curlHeaderArgument: String? {
        guard !file.contains("'"), !file.contains("\n") else { return nil }
        var quoted = "\"@"
        for character in file {
            if "\\\"$`".contains(character) { quoted.append("\\") }
            quoted.append(character)
        }
        return quoted + "\""
    }
}
