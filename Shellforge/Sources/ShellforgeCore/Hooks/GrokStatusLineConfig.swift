// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/GrokStatusLineConfig.swift), GPLv3, Laurens D'Hondt.
import Foundation

enum GrokStatusLineState: Equatable, Sendable {
    case missing, current, outdated, foreign(String), builtin, unsupportedLayout
}

/// Shellforge's half of Grok Build's `[ui.status_line]` in `~/.grok/config.toml`: the only surface where
/// Grok reports how full a session's context is. Install points it at the bundled shim, which runs
/// the command the user had before, if any. A built-in status line, or one written in a form this
/// editor does not handle, is left exactly as it is; every other byte of the file is kept.
enum GrokStatusLineConfig {
    static let path = ".grok/config.toml"
    static let shimName = "shellforge-grok-statusline.sh"
    static let disabledTypes: Set<String> = ["disabled", "off", "none", "hidden"]

    /// Grok runs `command` directly when it names an executable, through `sh -c` otherwise, so a
    /// path with spaces is shell-quoted.
    static func command(forShim path: String) -> String { ShellWords.word(path) }

    static func isOurShim(_ command: String) -> Bool {
        let bare = command.count > 1 && command.hasPrefix("'") && command.hasSuffix("'") ? String(command.dropFirst().dropLast()) : command
        return URL(fileURLWithPath: bare).lastPathComponent == shimName
    }

    static let tablePath = ["ui", "status_line"]

    /// The `[ui.status_line]` table's index, or `unsupported` when the status line is set some other
    /// way — an inline table, a dotted key, a sub-table, an array of tables, a second
    /// `[ui.status_line]` — or when `ui` is itself a value, which no header can add to. Found by
    /// each key's parsed path, so `"ui" . status_line` is caught and `status_line_width` is not:
    /// appending a table the file already declares fails Grok's whole config.
    private static func locate(_ tables: [TOMLStatements.Table]) -> (index: Int?, unsupported: Bool) {
        var index: Int?
        for (i, table) in tables.enumerated() {
            if table.path == tablePath, !table.array {
                if index != nil { return (nil, true) }
                index = i
                continue
            }
            if table.path.starts(with: tablePath) { return (nil, true) }
            for key in table.statements.compactMap(\.keyPath) {
                let path = table.path + key
                if path.starts(with: tablePath) || tablePath.starts(with: path) { return (nil, true) }
            }
        }
        return (index, false)
    }

    /// Our shim is current only as Install writes it, this bundle's path quoted as `command(forShim:)`
    /// quotes it; any other copy is outdated. Claude's card is more lenient, and says why
    /// (`ClaudeSettings.isInstalled`).
    static func state(_ text: String?, shimPath: String) -> GrokStatusLineState {
        guard let text else { return .missing }
        let tables = TOMLStatements.tables(text)
        let (index, unsupported) = locate(tables)
        if unsupported { return .unsupportedLayout }
        guard let index else { return .missing }
        // A `type` or `command` that is there but not one readable string is not a missing one:
        // merging would drop the user's command and forget the saved original.
        let unreadable = tables[index].statements.contains { statement in
            guard let key = statement.keyPath, ["type", "command"].contains(key[0]) else { return false }
            return key.count > 1 || statement.value == nil
        }
        if unreadable { return .unsupportedLayout }
        let values = tables[index].values
        guard let type = values["type"]?.lowercased(), !disabledTypes.contains(type) else { return .missing }
        if type == "builtin" { return .builtin }
        guard type == "command" else { return .unsupportedLayout }
        guard let command = values["command"], !command.isEmpty else { return .missing }
        if isOurShim(command) { return command == self.command(forShim: shimPath) ? .current : .outdated }
        return .foreign(command)
    }

    /// The file pointed at the shim, and the foreign command it replaced; `nil` when nothing is to change.
    static func merge(_ text: String?, shimPath: String) -> (text: String, replaced: String?)? {
        let current = state(text, shimPath: shimPath)
        switch current {
        case .current, .builtin, .unsupportedLayout: return nil
        case .missing, .outdated, .foreign: break
        }
        let escaped = command(forShim: shimPath).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let lines = "type = \"command\"\ncommand = \"\(escaped)\"\n"
        let source = text ?? ""
        let tables = TOMLStatements.tables(source)
        let result: String
        if let index = locate(tables).index {
            let table = tables[index]
            var header = table.statements[0].text
            if !header.hasSuffix("\n") { header += "\n" }
            let kept = table.statements.dropFirst().filter { $0.key != "type" && $0.key != "command" }
            let rewritten = header + lines + kept.map(\.text).joined()
            result = tables.enumerated().map { $0.offset == index ? rewritten : $0.element.text }.joined()
        } else {
            var base = source
            if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
            result = base + (base.isEmpty ? "" : "\n") + "[ui.status_line]\n" + lines
        }
        if case .foreign(let replaced) = current { return (result, replaced) }
        return (result, nil)
    }

    /// Points `file`, whose text the caller has read (`nil` when there is none), at the shim, with
    /// the user's own command kept first (`StatusLineOriginal.record`). `original` is where.
    static func install(_ text: String?, into file: UserConfigFile, original: URL, shimPath: String) throws {
        guard let merged = merge(text, shimPath: shimPath) else { return }
        let before: StatusLineOriginal.Before
        switch state(text, shimPath: shimPath) {
        case .foreign(let command): before = .foreign(command)
        case .missing: before = .missing
        case .current, .outdated, .builtin, .unsupportedLayout: before = .ours
        }
        try StatusLineOriginal.record(before, command: original)
        try file.backUp()
        try file.write(Data(merged.text.utf8))
    }
}
