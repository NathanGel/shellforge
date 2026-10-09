// Ported from AiTerm (app/Sources/AiTermCore/Hooks/CodexHookConfig.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// What Shellforge merges into Codex's `config.toml` — command hooks for its lifecycle events and an
/// MCP server for `Stop` — and how it recognises its own tables there. `CodexHooks` reads and
/// writes the file.
///
/// The merge works on a lossless view of TOML statements, used only to remove tables we own. In
/// particular, a marker comment is not a boundary: Codex can move hooks out of it and approval
/// records into it. Strings, comments, multiline values and unrelated tables retain their original
/// bytes.
enum CodexHookConfig {
    static let events = ["SessionStart", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "PermissionRequest"]
    static let begin = "# >>> shellforge hooks >>>", end = "# <<< shellforge hooks <<<"

    /// The canonical driver tables, with markers for humans reading the file.
    static func block(hookURL: String) -> String {
        var block = begin + "\n"
        // Codex starts command hooks in the session cwd. A merge workflow can remove that cwd
        // before Stop fires, making curl fail to spawn with ENOENT. Keep the final lifecycle event
        // on a persistent MCP connection instead; the other events remain lightweight async posts.
        block += "[mcp_servers.shellforge_hooks]\n"
        block += "url = \"\(hookURL)/mcp\"\nenabled = true\nrequired = false\nenabled_tools = [\"post_codex_hook\"]\n\n"
        block += "[mcp_servers.shellforge_hooks.http_headers]\nX-Shellforge-Hook = \"1\"\n\n"
        block += "[mcp_servers.shellforge_hooks.env_http_headers]\nX-Shellforge-iTerm-Session = \"ITERM_SESSION_ID\"\n\n"
        for event in events {
            block += "[[hooks.\(event)]]\nmatcher = \"\"\n[[hooks.\(event).hooks]]\n"
            if event == "Stop" {
                block += "type = \"mcp_tool\"\nserver = \"shellforge_hooks\"\ntool = \"post_codex_hook\"\n"
                block += "input = { session_id = \"${session_id}\", cwd = \"${cwd}\", hook_event_name = \"${hook_event_name}\", model = \"${model}\", turn_id = \"${turn_id}\", stop_hook_active = \"${stop_hook_active}\", last_assistant_message = \"${last_assistant_message}\" }\n"
                block += "timeout = 5\n\n"
            } else {
                block += "type = \"command\"\ncommand = 'curl -s -m 2 -X POST -H \"Content-Type: application/json\" -H \"X-Shellforge-Hook: 1\" -H \"X-Shellforge-iTerm-Session: $ITERM_SESSION_ID\" -H \"Expect:\" --data-binary @- \(hookURL)/hook/codex'\ntimeout = 5\nasync = true\n\n"
            }
        }
        return block + end
    }

    /// Exactly the tables a merge writes, so a merge would change nothing.
    static func isInstalled(_ text: String, daemonPort: Int) -> Bool {
        merge(text, hookURL: "http://127.0.0.1:\(daemonPort)") == text
    }

    /// Recognise owned tables even after Codex moves them away from the marker comments.
    static func isOwned(_ text: String) -> Bool {
        let parsed = TOMLStatements.tables(text)
        return parsed.contains(where: \.owned) || parsed.contains { $0.statements.contains(where: \.marker) }
    }

    /// The key that makes the merge impossible: an event of ours, or `hooks` itself, already set
    /// by an inline or dotted assignment (`hooks.Stop = […]`, `Stop = […]` under `[hooks]`,
    /// `hooks = {…}`), as a plain `[hooks.Stop]` table, or as a table a deeper header implies
    /// (`[hooks.Stop.x]` with no `[[hooks.Stop]]` before it). TOML forbids extending any of them
    /// with `[[hooks.Stop]]`, so appending Shellforge’s block would make Codex refuse the whole file.
    static func conflict(in text: String) -> String? {
        let events = Set(Self.events)
        var arrayParents: Set<String> = []
        for table in TOMLStatements.tables(text) {
            if table.path.count >= 2, table.path[0] == "hooks", events.contains(table.path[1]) {
                if table.array, table.path.count == 2 { arrayParents.insert(table.path[1]) }
                else if table.path.count == 2 || !arrayParents.contains(table.path[1]) { return "hooks.\(table.path[1])" }
            }
            // Keys inside `[[hooks.<event>]]` and its children are that entry's own fields.
            guard table.path.count < 2 else { continue }
            for key in table.statements.compactMap(\.keyPath) {
                let path = table.path + key
                if path == ["hooks"] { return "hooks" }
                if path.count >= 2, path[0] == "hooks", events.contains(path[1]) { return "hooks.\(path[1])" }
            }
        }
        return nil
    }

    /// Codex rewrites TOML tables independently of comments, so markers alone cannot delimit
    /// ownership. Reconcile the actual hook tables, including entries moved outside the markers.
    static func merge(_ toml: String?, hookURL: String) -> String {
        let text = toml ?? ""
        let parsed = TOMLStatements.tables(text)
        let block = Self.block(hookURL: hookURL)
        let markers = parsed.flatMap(\.statements).filter(\.marker)
        // Keep a pristine managed block in place, including on a port change. Do not use this
        // shortcut when there are moved/duplicated hooks or foreign content inside the markers.
        if markers.count == 2, let range = blockRange(in: text),
           let oldURL = parsed.first(where: { $0.path == ["mcp_servers", "shellforge_hooks"] })?.values["url"],
           oldURL.hasSuffix("/mcp"),
           text[range] == Self.block(hookURL: String(oldURL.dropLast(4))) {
            let outside = String(text[..<range.lowerBound]) + String(text[range.upperBound...])
            if !TOMLStatements.tables(outside).contains(where: \.owned) {
                var result = text; result.replaceSubrange(range, with: block); return result
            }
        }

        var removed = Set(parsed.indices.filter { parsed[$0].owned })
        // TOML child tables refer to the most recent parent of that name, even across unrelated
        // tables. Track that relationship rather than assuming children are adjacent.
        var parents: [String: Int] = [:], hooks: [String: Int] = [:], children: [Int: [Int]] = [:]
        for i in parsed.indices {
            let table = parsed[i]
            guard table.path.count >= 2, table.path[0] == "hooks" else { continue }
            let event = table.path[1]
            if table.array && table.path.count == 2 {
                parents[event] = i; hooks[event] = nil
            } else if table.path.count > 2 {
                if let parent = parents[event] { children[parent, default: []].append(i) }
                if table.path[2] == "hooks" {
                    if table.array && table.path.count == 3 { hooks[event] = i }
                    else if let hook = hooks[event], removed.contains(hook) { removed.insert(i) }
                }
            }
        }
        for (parent, descendants) in children where descendants.allSatisfy({ removed.contains($0) }) {
            removed.insert(parent)
        }
        var base = parsed.indices.map { i in
            if !removed.contains(i) { return parsed[i].textWithoutMarkers }
            // A standalone comment following an owned table may document the next foreign
            // table. Ownership of a hook never grants ownership of those comments.
            return parsed[i].statements.filter {
                !$0.marker && $0.code.isEmpty && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#")
            }.map(\.text).joined()
        }.joined()
        if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
        return base + (base.isEmpty ? "" : "\n") + block + "\n"
    }

    private static func blockRange(in text: String) -> Range<String.Index>? {
        var offset = text.startIndex, begin: String.Index?
        for statement in TOMLStatements.statements(text) {
            let end = text.index(offset, offsetBy: statement.text.count)
            if statement.marker {
                if statement.text.trimmingCharacters(in: .whitespacesAndNewlines) == Self.begin {
                    begin = offset
                } else if let begin, let marker = text.range(of: Self.end, range: offset..<end) {
                    return begin..<marker.upperBound
                }
            }
            offset = end
        }
        return nil
    }
}

private extension TOMLStatements.Statement {
    var marker: Bool {
        code.isEmpty && [CodexHookConfig.begin, CodexHookConfig.end].contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private extension TOMLStatements.Table {
    var owned: Bool {
        if path.starts(with: ["mcp_servers", "shellforge_hooks"]) { return true }
        guard array, path.count == 3, path[0] == "hooks", path[2] == "hooks" else { return false }
        let fields = values
        if fields["type"] == "mcp_tool" {
            return fields["server"] == "shellforge_hooks" && fields["tool"] == "post_codex_hook"
        }
        guard fields["type"] == "command", let command = fields["command"] else { return false }
        // Both the explicit ownership header and our endpoint are required. A mention of
        // Shellforge in an unrelated command or comment is not permission to delete that hook.
        return command.hasPrefix("curl ")
            && command.range(of: #"X-Shellforge-Hook: 1"#, options: .regularExpression) != nil
            && command.range(of: #"http://(?:127\.0\.0\.1|localhost):[0-9]+/hook/codex(?:['"\s]|$)"#, options: .regularExpression) != nil
    }
    /// The table as Codex's merge writes it back: marker comments are dropped and re-emitted.
    var textWithoutMarkers: String { statements.filter { !$0.marker }.map(\.text).joined() }
}
