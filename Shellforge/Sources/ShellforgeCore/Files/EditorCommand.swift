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

    /// What the tab runs: the editor on `file`, replacing the shell, so the tab closes with it. The
    /// editor stays as set (`code -w` keeps its argument); the file is the shell's argument, never
    /// typed, behind `--` for an editor that takes it. Throws `FileCommand.Unsafe` for a name with a
    /// control character.
    public static func command(editor: String, file: String) throws -> FileCommand {
        let endOfOptions = FileCommand.acceptsEndOfOptions(editor) ? " --" : ""
        return FileCommand(parts: [.text(editor + endOfOptions + " "), .path(0)], paths: [try FileCommand.argument(file)],
                           keepsShell: false)
    }
}
