// Ported from AiTerm (app/Sources/AiTermCore/Hooks/StatusLineOriginal.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The user's own status line, kept when Shellforge's shim takes its place: the shim runs it and prints
/// what it prints, so the user loses nothing. Claude Code's driver and Grok Build's each keep one,
/// as a plain-text command file the shim reads on every tick, and decide what to do with it by the
/// same rule (`record`).
public enum StatusLineOriginal {
    /// What the agent's status line was before an install, as the driver reads it off the agent's
    /// own config.
    enum Before: Equatable {
        /// The user has none: no status line, a disabled one, or one with no command to run.
        case missing
        /// Shellforge's shim, a moved bundle's included: whatever was kept is still the user's.
        case ours
        /// The user's own command, which the shim is about to replace.
        case foreign(String)
    }

    /// Keeps what the install is about to replace, before it writes the agent's config, so a
    /// failure between the two can never leave the agent on the shim with no record of the user's
    /// own status line. A foreign command is saved; with none, the record is forgotten, or a repair
    /// would bring back a status line the user removed; behind our own shim it stays as it is, which
    /// is how a moved bundle is repaired.
    /// AiTerm, the app Shellforge replaces, puts its own shim in the same slot and keeps the user's
    /// command in its support folder. A status line that is AiTerm's shim is not the user's: the
    /// command AiTerm kept is, so that is what Shellforge keeps, and its shim never runs AiTerm's.
    /// Otherwise a Repair in AiTerm would save Shellforge's shim as its "user command", and each
    /// shim would run the other; and once AiTerm is gone, the user's status line would go with it.
    /// AiTerm's record is read, never written. With no record behind AiTerm's shim there is no
    /// command of the user's, and nothing is kept.
    static func handedOver(_ before: Before, home: URL, aitermShim: String, aitermRecord: String) -> Before {
        guard case .foreign(let command) = before, shimName(command) == aitermShim else { return before }
        let record = home.appendingPathComponent("Library/Application Support/AiTerm").appendingPathComponent(aitermRecord)
        guard let kept = try? String(contentsOf: record, encoding: .utf8), !kept.isEmpty,
              !shimName(kept).hasPrefix("shellforge-") else { return .missing }
        return .foreign(kept)
    }

    /// The file name a status-line command runs, with any single quotes `ShellWords.word` added
    /// taken off: `'/My Apps/AiTerm.app/…/claude-statusline-shim.sh'` → `claude-statusline-shim.sh`.
    static func shimName(_ command: String) -> String { URL(fileURLWithPath: unquoted(command)).lastPathComponent }

    /// The path a command that is one word names, without the single quotes `ShellWords.word` adds.
    static func unquoted(_ command: String) -> String {
        let bare = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard bare.count >= 2, bare.hasPrefix("'"), bare.hasSuffix("'") else { return bare }
        return String(bare.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
    }

    static func record(_ before: Before, command: URL) throws {
        switch before {
        case .foreign(let original):
            try FileManager.default.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(original.utf8).write(to: command, options: .atomic)
        case .missing:
            if FileManager.default.fileExists(atPath: command.path) {
                try FileManager.default.removeItem(at: command)
            }
        case .ours:
            break
        }
    }
}
