// Ported from AiTerm (app/Sources/AiTermCore/Agents/SkillCatalog.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// One thing the user can type at the start of the first prompt: a slash command or a skill the
/// chosen agent actually has on this machine.
public struct AgentCompletion: Equatable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable { case skill, command }
    public enum Source: Equatable, Hashable, Sendable {
        case user, project, plugin(String), builtIn
        public var label: String {
            switch self {
            case .user: return "user"
            case .project: return "project"
            case .plugin(let name): return name
            case .builtIn: return "built-in"
            }
        }
    }
    public var name: String, kind: Kind, detail: String?, source: Source
    public var id: String { name }
    public init(name: String, kind: Kind, detail: String?, source: Source) {
        self.name = name; self.kind = kind; self.detail = detail; self.source = source
    }
}

/// Where the completion popup should attach itself: the token under the caret.
public struct CompletionTrigger: Equatable, Sendable {
    public var query: String, range: Range<Int>
}

/// Reads the slash commands and skills the agent CLIs keep on disk. Nothing here is hard-coded per
/// machine: the same directories the CLI itself reads are walked, so a skill installed after AiTerm
/// shipped shows up without an app update.
public enum SkillCatalog {
    static let maxDepth = 4
    public static let matchLimit = 8

    // -- discovery ------------------------------------------------------------------

    /// What one discovery found, and the stamps of everything it looked at to find it.
    private struct Discovery: Sendable { let stamps: FileStamps, found: [AgentCompletion] }

    /// Every agent's, home's and project's last discovery. Each sheet opening and each agent picked
    /// in one asked again: dozens of directory listings, and every `SKILL.md` read. Now a discovery
    /// stands while nothing it looked at has changed — no directory it listed, no file it read, no
    /// path it found missing — which a `stat` of each tells.
    private static let discoveries = KeyedStates<Discovery?>(nil)

    public static func discover(agentId agent: String, projectPath: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentCompletion] {
        let key = [agent, home.path, projectPath ?? ""].joined(separator: "\u{0}")
        return discoveries.withState(for: key) { known in
            if let known, known.stamps.areCurrent { return known.found }
            let walk = Walk()
            let found = discover(agentId: agent, projectPath: projectPath, home: home, walk: walk)
            known = Discovery(stamps: walk.stamps, found: found)
            return found
        }
    }

    /// The paths a discovery looked at, each stamped just before it was: a directory before it is
    /// listed, a file before it is read, a path whose existence was asked before it was asked. A
    /// change after the stamp is a change the next discovery sees.
    final class Walk {
        private var paths: [String] = [], taken: [FileStamps.Stamp?] = [], seen = Set<String>()

        func look(at path: String) {
            guard seen.insert(path).inserted else { return }
            paths.append(path)
            taken.append(FileStamps.stamp(path))
        }

        var stamps: FileStamps { FileStamps(files: paths, stamps: taken) }
    }

    private static func discover(agentId agent: String, projectPath: String?, home: URL, walk: Walk) -> [AgentCompletion] {
        var found: [AgentCompletion] = []
        for root in SkillRoots.roots(agentId: agent, home: home, project: projectPath.map(URL.init(fileURLWithPath:))) {
            switch root.kind {
            case .skills(let namespace, let hidingNonInvocable):
                found += skills(in: root.url, namespace: namespace, source: root.source, hidingNonInvocable: hidingNonInvocable, walk: walk)
            case .commands(let namespace, let depth):
                found += commands(in: root.url, namespace: namespace, source: root.source, depth: depth, walk: walk)
            case .plugins(let hidingNonInvocable):
                found += pluginCompletions(under: root.url, hidingNonInvocable: hidingNonInvocable, walk: walk)
            }
        }

        // First writer wins, so a project command does not shadow the user one it shares a name
        // with — and the list is sorted, because the popup shows it in order.
        var seen = Set<String>()
        return found.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }

    private static func pluginCompletions(under userRoot: URL, hidingNonInvocable: Bool, walk: Walk) -> [AgentCompletion] {
        pluginRoots(under: userRoot.appendingPathComponent("plugins"), walk: walk).flatMap { plugin in
            skills(in: plugin.url.appendingPathComponent("skills"), namespace: plugin.name, source: .plugin(plugin.name),
                   hidingNonInvocable: hidingNonInvocable, walk: walk)
                + commands(in: plugin.url.appendingPathComponent("commands"), namespace: plugin.name, source: .plugin(plugin.name), walk: walk)
        }
    }

    /// Every `<marketplace>/<plugin>/<version>` directory that holds a plugin. The deepest
    /// directory wins per plugin name (a newer version sorts after an older one, its numbers
    /// compared as numbers so `6.10.0` beats `6.9.0`), and buckets that hold no skills or commands
    /// are skipped.
    static func pluginRoots(under pluginsDir: URL, walk: Walk) -> [(name: String, url: URL)] {
        var out: [String: URL] = [:]
        for base in ["cache", "synced"] {
            let dir = pluginsDir.appendingPathComponent(base)
            for candidate in descend(dir, depth: 3, walk: walk) where isPluginRoot(candidate, walk: walk) {
                // <…>/<plugin>/<version> and <…>/<plugin> are both seen; the plugin name is the
                // directory that owns the skills, or its parent when a version sits in between.
                let name = pluginName(for: candidate)
                if let existing = out[name], existing.path.compare(candidate.path, options: .numeric) == .orderedDescending { continue }
                out[name] = candidate
            }
        }
        return out.map { (name: $0.key, url: $0.value) }.sorted { $0.name < $1.name }
    }

    static func isPluginRoot(_ url: URL, walk: Walk) -> Bool {
        ["skills", "commands"].contains { name in
            let folder = url.appendingPathComponent(name)
            walk.look(at: folder.path)
            return isDirectory(folder)
        }
    }

    static func pluginName(for root: URL) -> String {
        let last = root.lastPathComponent
        // A version directory (`6.3.0`, `v1.2`) is not the plugin's name; its parent is.
        let isVersion = last.first.map { $0.isNumber || $0 == "v" } == true && last.contains(".")
        return isVersion ? root.deletingLastPathComponent().lastPathComponent : last
    }

    /// Directories that hold a `SKILL.md`. The search descends, so it finds a plain
    /// `skills/<name>/SKILL.md`, a Codex built-in under `skills/.system/<name>/SKILL.md` and a
    /// claude.ai skill under `skills/synced/<bucket>/<name>/SKILL.md` alike — in every case the
    /// skill's name is its own directory, never the bucket's.
    ///
    /// `hidingNonInvocable` drops a skill whose frontmatter says `user-invocable: false`, for the
    /// CLIs that keep such a skill out of their slash menu (Claude Code, Grok); Codex and PI
    /// document no such key.
    static func skills(in root: URL, namespace: String?, source: AgentCompletion.Source,
                       hidingNonInvocable: Bool = false, walk: Walk) -> [AgentCompletion] {
        descend(root, depth: maxDepth, walk: walk).compactMap { dir in
            let manifest = dir.appendingPathComponent("SKILL.md")
            walk.look(at: manifest.path)
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            let fields = frontmatter(of: manifest)
            if hidingNonInvocable, fields["user-invocable"]?.lowercased() == "false" { return nil }
            let name = fields["name"].map(leafName) ?? dir.lastPathComponent
            return AgentCompletion(name: qualify(name, with: namespace), kind: .skill,
                                   detail: fields["description"], source: source)
        }
    }

    /// Markdown files under a commands (or Codex prompts) directory. A file in a subdirectory is
    /// namespaced with a colon, which is how Claude Code addresses it.
    ///
    /// The path walked down is carried as `prefix` rather than subtracted from the file's path
    /// afterwards: `contentsOfDirectory` hands back `/private/var/...` for a URL built from
    /// `/var/...`, so trimming the root off the string produced names like `/privatedeploy`.
    static func commands(in root: URL, namespace: String?, source: AgentCompletion.Source,
                         prefix: [String] = [], depth: Int = maxDepth, walk: Walk) -> [AgentCompletion] {
        let listed = root.resolvingSymlinksInPath()
        walk.look(at: root.path); walk.look(at: listed.path)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: listed, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [AgentCompletion] = []
        for entry in entries {
            let component = entry.lastPathComponent
            guard !component.hasPrefix(".") else { continue }
            if isDirectory(entry) {
                guard depth > 0, !isSkipped(component) else { continue }
                out += commands(in: entry, namespace: namespace, source: source, prefix: prefix + [component], depth: depth - 1, walk: walk)
            } else if entry.pathExtension == "md", component != "SKILL.md" {
                let name = (prefix + [entry.deletingPathExtension().lastPathComponent]).joined(separator: ":")
                walk.look(at: entry.path)
                out.append(AgentCompletion(name: qualify(name, with: namespace), kind: .command,
                                           detail: frontmatter(of: entry)["description"], source: source))
            }
        }
        return out
    }

    static func qualify(_ name: String, with namespace: String?) -> String {
        guard let namespace, !namespace.isEmpty, !name.hasPrefix(namespace + ":") else { return name }
        return namespace + ":" + name
    }

    /// A `name:` in frontmatter may already be namespaced (`superpowers:brainstorming`); only the
    /// last part is the skill, the namespace is re-applied from where the file was found.
    static func leafName(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

    /// Every directory under `root`, to a bounded depth, skipping the noise that agent homes are
    /// full of (`node_modules`, `.git`, `assets`, `references`, `scripts`) — a skill never hides in
    /// one of those, and walking them costs real time on a large install.
    static let skipped: Set<String> = ["node_modules", ".git", "assets", "references", "scripts", "tests", "docs", "hooks", "agents"]

    /// Hidden directories are skipped too — Claude Code parks a removed skill under
    /// `skills/.trash/<id>/`, and plugins keep only manifests in theirs — bar Codex's built-ins,
    /// which live under `skills/.system`.
    static func isSkipped(_ name: String) -> Bool {
        skipped.contains(name) || (name.hasPrefix(".") && name != ".system")
    }

    /// A directory, or a symlink to one: a skill shared between agents is usually a symlink in each
    /// agent's folder, and every CLI follows it. A link that loops back up the tree is harmless —
    /// the walk is depth-bounded and a name is offered once.
    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func descend(_ root: URL, depth: Int, walk: Walk) -> [URL] {
        guard depth > 0 else { return [] }
        // A symlinked directory is not listed through the link itself, only through its target.
        let listed = root.resolvingSymlinksInPath()
        walk.look(at: root.path); walk.look(at: listed.path)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: listed, includingPropertiesForKeys: [.isDirectoryKey],
                                                                        options: [.skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for entry in entries where !isSkipped(entry.lastPathComponent) && isDirectory(entry) {
            out.append(entry)
            out += descend(entry, depth: depth - 1, walk: walk)
        }
        return out
    }

    // -- frontmatter ----------------------------------------------------------------

    /// The value of one key in a `---` frontmatter block, including the folded (`>-`, `|`) form
    /// that longer skill descriptions use.
    public static func frontmatterValue(_ key: String, in text: String) -> String? {
        frontmatter(in: text)[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every key of a `---` frontmatter block, read in one pass; the first of a key wins, and a key
    /// with nothing after it reads as empty.
    static func frontmatter(in text: String) -> [String: String] {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(end...)
        }
        var values: [String: String] = [:]
        var i = 1
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value == ">" || value == ">-" || value == "|" || value == "|-" {
                var folded: [String] = []
                while i < lines.count, lines[i].hasPrefix("  ") {
                    folded.append(lines[i].trimmingCharacters(in: .whitespaces)); i += 1
                }
                value = folded.joined(separator: " ")
            }
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if values[key] == nil { values[key] = value }
        }
        return values.filter { !$0.value.isEmpty }
    }

    /// `url`'s frontmatter, from as much of the file as holds it: a skill's body can run to pages,
    /// and only the block at its top is read. Each line is looked at once, as it arrives. What was
    /// read is decoded leniently: the last chunk can end inside a character of the body.
    static func frontmatter(of url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        var data = Data(), lineStart = 0
        reading: while let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty {
            data.append(chunk)
            while let newline = data[lineStart...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: data[lineStart..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                // A first line that is not `---` says there is no block; a later `---` closes it.
                let opensNone = lineStart == 0 && line != "---", closes = lineStart > 0 && line == "---"
                lineStart = newline + 1
                if opensNone || closes { break reading }
            }
        }
        return frontmatter(in: String(decoding: data, as: UTF8.self))
    }

    // -- matching -------------------------------------------------------------------

    /// Prefix matches first, then matches anywhere in the name; alphabetical within each group so
    /// the popup does not reshuffle as the list is filtered.
    public static func matches(_ items: [AgentCompletion], query: String, limit: Int = matchLimit) -> [AgentCompletion] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(items.prefix(limit)) }
        var prefixed: [AgentCompletion] = [], contained: [AgentCompletion] = []
        for item in items {
            let name = item.name.lowercased()
            if name.hasPrefix(q) { prefixed.append(item) }
            // `superpowers:brainstorming` should answer to "brainstorming", so the part after the
            // namespace counts as a prefix too.
            else if let leaf = name.split(separator: ":").last, leaf.hasPrefix(q) { prefixed.append(item) }
            else if name.contains(q) { contained.append(item) }
        }
        return Array((prefixed + contained).prefix(limit))
    }

    // -- trigger --------------------------------------------------------------------

    /// `/` is the one key that opens the popup, whatever the agent: the person learns one key, and
    /// the picked item is written the way its agent invokes it (`invocation(of:for:)`).
    public static let trigger: Character = "/"

    /// The token the caret sits in, when it is a command token: it starts at the beginning of a
    /// word, opens with `/`, and has no whitespace in it. `range` covers the `/` and the typed
    /// query, which is what a picked completion replaces. Only with the caret at the token's end:
    /// a pick mid-word would leave the rest of the word behind ("/brainstorming rain"), so there
    /// Shellforge offers none, where AiTerm did.
    public static func trigger(in text: String, caret: Int) -> CompletionTrigger? {
        let chars = Array(text)
        guard caret >= 0, caret <= chars.count else { return nil }
        guard caret == chars.count || chars[caret].isWhitespace else { return nil }
        var start = caret
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        guard start < caret, chars[start] == trigger else { return nil }
        let query = String(chars[(start + 1)..<caret])
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return CompletionTrigger(query: query, range: start..<caret)
    }

    /// What a picked completion writes into the prompt: a command after `/`, a skill after its
    /// agent's sigil — `$` for Codex, which keeps `/` for its commands, and `/` for the others.
    public static func invocation(of item: AgentCompletion, agentId agent: String) -> String {
        let sigil = item.kind == .skill ? SkillRoots.sigil(agentId: agent) : "/"
        return String(sigil) + item.name
    }
}
