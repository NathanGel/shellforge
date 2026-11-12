import Combine
import Foundation
import ShellforgeCore

/// Settings › Core › Terminal editor: the command files open with. Empty means `$EDITOR`, else `vi`.
@MainActor
public final class TerminalEditorSettings: ObservableObject {
    private let defaults: UserDefaults
    private let environment: @Sendable () -> [String: String]
    /// The login environment's `$EDITOR`, once read; nil until then, and when it is not set.
    @Published private(set) var environmentEditor: String?
    /// The saved command, or empty.
    let saved: String

    /// `environment` reads the launcher's login environment, which can run a login shell: only
    /// `load` calls it, off the main actor.
    public init(defaults: UserDefaults, environment: @escaping @Sendable () -> [String: String]) {
        self.defaults = defaults
        self.environment = environment
        saved = defaults.string(forKey: EditorCommand.settingKey) ?? ""
    }

    /// Reads `$EDITOR` off the main actor.
    func load() async {
        let read = environment
        let editor = await BackgroundWork.run { read()["EDITOR"] }
        // Blank counts as unset, as `EditorCommand.editor` treats it.
        let trimmed = editor?.trimmingCharacters(in: .whitespacesAndNewlines)
        environmentEditor = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The field's placeholder: what would be used with nothing saved.
    var placeholder: String { environmentEditor.map { "$EDITOR (\($0))" } ?? "vi" }

    /// The status line with an empty draft.
    var emptyStatus: String { environmentEditor == nil ? "Uses vi" : "From $EDITOR" }

    /// A sheet's Save: one command line, so newlines become spaces; an empty draft removes the setting.
    func save(_ draft: String) {
        let line = draft.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if line.isEmpty { defaults.removeObject(forKey: EditorCommand.settingKey) } else { defaults.set(line, forKey: EditorCommand.settingKey) }
    }
}

extension SidebarModel {
    /// Settings › Core › Terminal editor, reading `$EDITOR` from this sidebar's launcher.
    func terminalEditorSettings(defaults: UserDefaults) -> TerminalEditorSettings {
        let launcher = self.launcher
        return TerminalEditorSettings(defaults: defaults, environment: { launcher.environment.variables })
    }
}
