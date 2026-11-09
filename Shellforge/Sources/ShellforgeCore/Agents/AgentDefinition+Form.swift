import Foundation

/// The agent as Settings › Agents' form shows it: its command and arguments as one line of text, and
/// the arguments that carry the first prompt as another.
extension AgentDefinition {
    /// The command and every argument group that doesn't hold `{prompt}`, as one line: each word as
    /// it is, or quoted when it holds a blank, a quote or a backslash, so `parseCommand` reads it back.
    public var commandText: String {
        ([command] + commandGroups.joined()).map(Self.formWord).joined(separator: " ")
    }

    /// The argument groups that hold `{prompt}`, as one line, or `{prompt}` alone when none does:
    /// the prompt then goes last.
    public var promptArgumentsText: String {
        let groups = promptGroups
        return groups.isEmpty ? Self.promptPlaceholder : groups.joined().map(Self.formWord).joined(separator: " ")
    }

    /// The argument groups that hold `{prompt}`.
    public var promptGroups: [[String]] { arguments.filter(Self.holdsPrompt) }

    /// The argument groups that don't hold `{prompt}`.
    public var commandGroups: [[String]] { arguments.filter { !Self.holdsPrompt($0) } }

    private static func holdsPrompt(_ group: [String]) -> Bool { group.contains { $0.contains(promptPlaceholder) } }

    /// `text` read as a shell reads it: the first word is the command, and the rest are in groups.
    /// Nil when a quote is never closed, or there is no word.
    public static func parseCommand(_ text: String) -> (command: String, arguments: [[String]])? {
        guard let words = ShellWords.split(text), let first = words.first else { return nil }
        return (first, group(Array(words.dropFirst())))
    }

    /// `text` as argument groups, or nil when a quote is never closed.
    public static func parseArguments(_ text: String) -> [[String]]? {
        ShellWords.split(text).map(group)
    }

    /// A word holding a placeholder (`{model}`, `{prompt}`…) joins the group of the word before it
    /// when that word is a flag, so `--model {model}` goes, or is left out, as one; every other word
    /// is a group of its own.
    static func group(_ words: [String]) -> [[String]] {
        var groups: [[String]] = []
        for word in words {
            let holdsPlaceholder = word.range(of: #"\{[^{}]*\}"#, options: .regularExpression) != nil
            if holdsPlaceholder, let previous = groups.last?.last, previous.hasPrefix("-") {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups
    }

    /// `s` bare when `ShellWords.split` reads it back unchanged, quoted otherwise. Looser than
    /// `ShellWords.word`, which is for a real shell: here `{model}` stays as it is written.
    static func formWord(_ s: String) -> String {
        let plain = !s.isEmpty && !s.contains { $0.isWhitespace || $0 == "'" || $0 == "\"" || $0 == "\\" }
        return plain ? s : ShellWords.quote(s)
    }

    /// The first word, of the command then the arguments, that can't be typed into a terminal safely,
    /// as the launch would refuse it: a control character, DEL or a backslash. Nil when there is none.
    public func unsafeWord() -> AgentCommand.UnsafeWord? {
        do {
            try AgentCommand.refuseUnsafe(command, field: "command", backslash: true)
            for word in arguments.joined() { try AgentCommand.refuseUnsafe(word, field: "arguments", backslash: true) }
            return nil
        } catch {
            return error as? AgentCommand.UnsafeWord
        }
    }
}
