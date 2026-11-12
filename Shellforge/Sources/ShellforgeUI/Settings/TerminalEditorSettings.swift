import Foundation
import ShellforgeCore

/// Settings › Core › Terminal editor: the command files open with. Empty means `$EDITOR`.
@MainActor
public final class TerminalEditorSettings {
    private let defaults: UserDefaults
    /// What is used while nothing is saved: `$EDITOR` from the login environment, else `vi`.
    let fallback: String
    /// The saved command, or empty.
    let saved: String

    /// `environment` is the launcher's resolved login environment.
    public init(defaults: UserDefaults = .standard, environment: [String: String]) {
        self.defaults = defaults
        saved = defaults.string(forKey: EditorCommand.settingKey) ?? ""
        fallback = EditorCommand.editor(setting: nil, environment: environment)
    }

    /// The field's placeholder: what would be used with nothing saved.
    var placeholder: String { fallback == "vi" ? "vi" : "$EDITOR (\(fallback))" }

    /// A sheet's Save: an empty draft removes the setting.
    func save(_ draft: String) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { defaults.removeObject(forKey: EditorCommand.settingKey) } else { defaults.set(trimmed, forKey: EditorCommand.settingKey) }
    }
}

extension SidebarModel {
    /// Settings › Core › Terminal editor, with the fallback from this sidebar's launcher.
    func terminalEditorSettings() -> TerminalEditorSettings {
        TerminalEditorSettings(environment: launcher.environment.variables)
    }
}
