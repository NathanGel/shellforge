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
    /// The editor stays as typed; only the file's word is guarded (`TypedPath`), behind `--` for an
    /// editor that takes it. Throws `TypedPath.Unsafe` for a name that can't be typed safely.
    public static func line(editor: String, file: String) throws -> String {
        let endOfOptions = TypedPath.acceptsEndOfOptions(editor) ? " --" : ""
        return "exec " + editor + endOfOptions + " " + (try TypedPath.word(file))
    }
}
