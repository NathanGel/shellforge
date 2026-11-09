import Foundation

/// The hook lines an agent with exact status needs: its own snippet for its settings file, or
/// three plain lines for the person to adapt when it has none.
public enum ExactStatusLines {
    /// The three lines that report each state through `statusCommand`, shell-quoted when it needs it:
    /// the app's path holds a space when it lives in a folder whose name does.
    public static func generic(statusCommand: String) -> String {
        let command = ShellWords.word(statusCommand)
        return ["working", "needs-input", "done"].map { "\(command) \($0)" }.joined(separator: "\n")
    }

    /// The agent's `statusSetup.snippet` with `{shellforge-status}` replaced by `statusCommand`,
    /// shell-quoted when it needs it and escaped for JSON when the settings file is a `.json` file;
    /// the generic lines when the agent has no setup.
    public static func lines(for agent: AgentDefinition, statusCommand: String) -> String {
        guard let setup = agent.statusSetup else { return generic(statusCommand: statusCommand) }
        let quoted = ShellWords.word(statusCommand)
        let command = setup.file.lowercased().hasSuffix(".json") ? jsonEscaped(quoted) : quoted
        return setup.snippet.replacingOccurrences(of: "{shellforge-status}", with: command)
    }

    /// `s` as it reads inside a JSON string, without the surrounding quotes.
    private static func jsonEscaped(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let text = String(data: data, encoding: .utf8) else { return s }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\/", with: "/")
    }
}
