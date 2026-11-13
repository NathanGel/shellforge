import Foundation

/// A file's path as one word of a line typed into a terminal tab: the editor's line and a diff's.
/// The path comes from the repository, so a cloned one decides it. A relative path goes behind
/// `./`, so no word starts with `+` or `-` and an editor never reads it as an option (vim runs
/// `+!cmd` and `-c!cmd`). A control character acts as a keystroke even inside quotes (^U erases the
/// open quote, CR runs the rest of the line), and a backslash ends the quote for fish, which reads
/// `\'` as an escape: a path holding either is refused, as `AgentCommand.refuseUnsafe` refuses an
/// agent's words.
public enum TypedPath {
    /// A path that can't be typed safely: nothing is opened for it.
    public struct Unsafe: Error, Equatable, LocalizedError {
        public init() {}
        public var message: String { "This file’s name can’t be typed safely into a terminal." }
        public var errorDescription: String? { message }
    }

    /// Editors whose command line takes `--` before file names.
    private static let endOfOptionsEditors: Set<String> = ["vi", "vim", "nvim"]

    /// Throws `Unsafe` for a path holding a control character, DEL or a backslash.
    public static func refuseUnsafe(_ path: String) throws {
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" }) { throw Unsafe() }
    }

    /// The path as a word of the line: checked, behind `./` when relative, and as a literal
    /// pathspec (`:(literal)…`) when `pathspec`, quoted as needed.
    public static func word(_ path: String, pathspec: Bool = false) throws -> String {
        try refuseUnsafe(path)
        let anchored = path.hasPrefix("/") ? path : "./" + path
        return AgentCommand.shellWord(pathspec ? ":(literal)" + anchored : anchored)
    }

    /// Whether `editor`, the command as typed (`nvim -p`), takes `--` before its file names: its
    /// first word's last path component is one known to.
    public static func acceptsEndOfOptions(_ editor: String) -> Bool {
        guard let program = editor.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return false }
        return endOfOptionsEditors.contains((String(program) as NSString).lastPathComponent)
    }
}
