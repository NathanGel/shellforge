import Foundation

/// The command that opens a file for editing in a terminal tab: the Settings choice, else `$EDITOR`
/// from the login environment, else `vi`.
public enum EditorCommand {
    public static let settingKey = "ShellforgeTerminalEditor"

    /// The editor to run, as typed — `code -w` and `nvim -p` keep their arguments. Blank counts as unset.
    public static func editor(setting: String?, environment: [String: String]) -> String {
        for candidate in [setting, environment["EDITOR"]] {
            if let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { return trimmed }
        }
        return "vi"
    }

    /// The line typed into the tab: the shell is replaced by the editor, so the tab closes with it.
    public static func line(editor: String, file: String) -> String {
        "exec " + editor + " " + AgentCommand.shellWord(file)
    }
}
