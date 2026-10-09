// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/ClaudeSettings.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// What Shellforge merges into Claude Code's `settings.json` — HTTP hooks for its lifecycle events and
/// the status-line shim — and how it recognises its own entries there. `ClaudeHooks` reads and
/// writes the file; launch asks only whether Claude Code still runs the usage shim.
public enum ClaudeSettings {
    static let events = ["SessionStart", "PostModelSwitch", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "Notification", "PermissionRequest"]
    /// Events Shellforge used to install and no longer does. `PreToolUse` was a *synchronous* Bash hook
    /// for a cleanup interception the daemon has since dropped, so every Bash tool call waited on a
    /// round trip that answered nothing. A merge removes Shellforge's own entries from these and leaves
    /// anyone else's in place.
    static let retiredEvents = ["PreToolUse"]
    static let marker = "_shellforge"

    static func isOurHook(_ hook: [String: Any]) -> Bool { hook[marker] as? Bool == true }
    static func holdsOurHook(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains(where: isOurHook) == true
    }

    private static func hook(hookURL: String) -> [String: Any] {
        ["type": "http", "url": hookURL, "headers": ["X-Shellforge-Hook": "1"],
         "timeout": 3, "async": true, marker: true]
    }

    private static func entry(hookURL: String) -> [String: Any] {
        ["matcher": "", "hooks": [hook(hookURL: hookURL)]]
    }

    /// Our shim, recognised by filename as well as by exact path: a moved app bundle
    /// leaves the old path in `settings.json`, and that command is still ours, not a foreign tool's.
    static func isOurShim(_ command: String, shimPath: String) -> Bool {
        command == shimPath || URL(fileURLWithPath: command).lastPathComponent == URL(fileURLWithPath: shimPath).lastPathComponent
    }

    /// `settings.json` is the user's file, so what we write changes only what we merge: no `\/` for
    /// every `/`, and sorted keys so a rerun produces the same bytes.
    static let jsonOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    /// `settings.json` as an object: no bytes, or none at all, is "no settings yet". Anything else
    /// that is not a JSON object — malformed JSON, or an array — is `nil`, and must
    /// never be merged as if empty: that would replace the user's settings with our entries alone.
    private static func object(_ json: Data?) -> [String: Any]? {
        guard let json, !json.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
    }

    /// The key whose shape the merge cannot work with, when there is one: `hooks` that is not an
    /// object, one of Shellforge's events that is not an array of objects (a single malformed element
    /// fails the cast for the whole array, so a merge would drop Emdash's valid entries beside it),
    /// or a `statusLine` that is not an object. Rewriting any of them would be silent data loss;
    /// the file is refused instead, as Codex's is for `hooks.Stop = [...]`. Events Shellforge does not
    /// manage are never looked at, and a key set to JSON's `null` is one that is not set: the
    /// merge fills it in as it would a missing one.
    private static func unmergeableKey(_ settings: [String: Any]) -> String? {
        if let value = set(settings["hooks"]) {
            guard let hooks = value as? [String: Any] else { return "hooks" }
            if let event = events.first(where: { event in set(hooks[event]).map { $0 as? [[String: Any]] == nil } ?? false }) {
                return "hooks.\(event)"
            }
        }
        if let line = set(settings["statusLine"]), line as? [String: Any] == nil { return "statusLine" }
        return nil
    }

    /// `value`, unless it is missing or JSON's `null`.
    private static func set(_ value: Any?) -> Any? { value is NSNull ? nil : value }

    /// Why the merge will not touch a `settings.json`, finishing "it …": the one place the Claude
    /// card's refusal is worded, which the probe shows and Install throws through the driver's
    /// `UserConfigFile`, the file that knows its own path.
    struct Unmergeable: Error, Equatable { let reason: String }

    /// `settings.json` as an object the merge can extend, or why it cannot.
    static func mergeable(_ json: Data?) throws(Unmergeable) -> [String: Any] {
        guard let settings = object(json) else { throw Unmergeable(reason: "is not a JSON object") }
        if let key = unmergeableKey(settings) { throw Unmergeable(reason: "sets \(key) in a form Shellforge cannot merge") }
        return settings
    }

    /// Throws `Unmergeable` for a file it must not rewrite.
    static func merge(_ json: Data?, hookURL: String, shimPath: String) throws -> (Data, originalStatusLine: [String: Any]?) {
        var obj = try mergeable(json)
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        for event in retiredEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.compactMap { entry -> [String: Any]? in
                guard let installed = entry["hooks"] as? [[String: Any]], installed.contains(where: isOurHook) else { return entry }
                let foreign = installed.filter { !isOurHook($0) }
                guard !foreign.isEmpty else { return nil }
                var entry = entry; entry["hooks"] = foreign; return entry
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        for event in events {
            var inserted = false
            var entries: [[String: Any]] = []
            for existing in hooks[event] as? [[String: Any]] ?? [] {
                guard let installed = existing["hooks"] as? [[String: Any]], installed.contains(where: isOurHook) else {
                    entries.append(existing); continue
                }
                // Replace our first occurrence in place; keep foreign hooks and their matcher.
                if !inserted {
                    entries.append(entry(hookURL: hookURL))
                    inserted = true
                }
                let foreign = installed.filter { !isOurHook($0) }
                if !foreign.isEmpty {
                    var kept = existing; kept["hooks"] = foreign; entries.append(kept)
                }
            }
            if !inserted { entries.append(entry(hookURL: hookURL)) }
            hooks[event] = entries
        }
        obj["hooks"] = hooks
        var original: [String: Any]? = nil
        let current = obj["statusLine"] as? [String: Any]
        let currentCommand = current?["command"] as? String
        // A moved bundle's old shim is repointed to `shimPath` but never saved as a "foreign"
        // original — saving it would make the shim wrap itself and recurse forever.
        if !(currentCommand.map { isOurShim($0, shimPath: shimPath) } ?? false) {
            original = current
        }
        if currentCommand != shimPath {
            // Only `type` and `command` are ours: the user's `padding`, and whatever a newer Claude
            // Code adds, ride along to the shim.
            var line = current ?? [:]
            line["type"] = "command"
            line["command"] = shimPath
            if line["padding"] == nil { line["padding"] = 0 }
            obj["statusLine"] = line
        }
        return (try JSONSerialization.data(withJSONObject: obj, options: jsonOptions), original)
    }

    private static func statusLineCommand(_ settings: [String: Any]) -> String? {
        (settings["statusLine"] as? [String: Any])?["command"] as? String
    }

    /// Is Shellforge's shim still Claude Code's status line? Claude Code hands `rate_limits` to the
    /// status line command and to nothing else, so this one entry is the whole Claude usage feed —
    /// and it lives in a file the user, Claude Code's own `/statusline`, and every other tool that
    /// edits `settings.json` can rewrite. `installHooksOnFirstRun`'s one-shot flag records that we
    /// once wrote it, not that it is still there, so the answer has to be read off the file itself.
    /// Matched by filename, like `merge`: a moved bundle is still our shim.
    /// `isRunnable` is the second half of the question: a command Claude Code cannot exec is not
    /// an installed status line, however right its name looks. A translocated bundle, a build
    /// deleted with its worktree and an app dragged to the Trash all leave the filename matching
    /// and the feed dead, and the footer has to say so rather than report health.
    static func statusLineIsInstalled(_ json: Data?, shimPath: String,
                                      isRunnable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        guard let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let command = statusLineCommand(obj) else { return false }
        return isOurShim(command, shimPath: shimPath) && isRunnable(command)
    }

    public static func statusLineIsInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser, shimPath: String) -> Bool {
        statusLineIsInstalled(try? Data(contentsOf: home.appendingPathComponent(ClaudeHooks.settingsPath)), shimPath: shimPath)
    }

    /// Exactly the hooks and status line a merge writes, and nothing retired left behind. The
    /// status line counts as current when it names this bundle's shim, or another copy of the shim
    /// that still runs — what the footer would call a working feed. A path that runs nothing, a
    /// moved or deleted bundle, is outdated: Repair repoints it.
    ///
    /// Grok's status line is current only at this bundle's exact path (`GrokStatusLineConfig`).
    /// Claude's tolerates a runnable copy because a second judge reads it: the footer says whether
    /// the Claude usage feed works by whether the shim it names can run
    /// (`statusLineIsInstalled`), and a card that called that same line outdated would contradict
    /// it — and, with another Shellforge build such as a worktree's running beside this one, offer a
    /// Repair each would undo for the other. Nothing else judges Grok's line, so its card asks
    /// for exactly what Install writes.
    static func isInstalled(_ settings: [String: Any], daemonPort: Int, shimPath: String,
                            isRunnable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let command = statusLineCommand(settings),
              command == shimPath || (isOurShim(command, shimPath: shimPath) && isRunnable(command)) else { return false }
        let hookURL = "http://127.0.0.1:\(daemonPort)" + ClaudeHooks.endpoint
        // A retired hook still in place is an outdated install: repairing it is what removes it.
        let retiredRemain = retiredEvents.contains { (hooks[$0] as? [[String: Any]])?.contains(where: holdsOurHook) == true }
        return !retiredRemain && events.allSatisfy { event in
            let ownedEntries = (hooks[event] as? [[String: Any]] ?? []).filter(holdsOurHook)
            guard ownedEntries.count == 1, let entry = ownedEntries.first,
                  entry["matcher"] as? String == "" else { return false }
            let owned = (entry["hooks"] as? [[String: Any]] ?? []).filter(isOurHook)
            guard owned.count == 1, let hook = owned.first else { return false }
            return (hook as NSDictionary) == (Self.hook(hookURL: hookURL) as NSDictionary)
        }
    }

    /// Whether a settings object contains any Shellforge-owned hook or status-line entry. This is
    /// deliberately broader than `isInstalled`: an old URL, a moved shim, or an incomplete owned
    /// hook set is still ours and can be repaired safely.
    static func isOwned(_ settings: [String: Any], shimPath: String) -> Bool {
        if let command = statusLineCommand(settings), isOurShim(command, shimPath: shimPath) { return true }
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: holdsOurHook) == true }
    }

    /// Whether a merge changed what the file says, not how it is written: another tool's key order,
    /// whitespace, escaped slashes or a float's digits are no reason to rewrite the user's file.
    static func same(_ original: Data?, _ merged: Data) -> Bool {
        guard let original, let before = try? JSONSerialization.jsonObject(with: original),
              let after = try? JSONSerialization.jsonObject(with: merged),
              let a = try? JSONSerialization.data(withJSONObject: before, options: jsonOptions),
              let b = try? JSONSerialization.data(withJSONObject: after, options: jsonOptions) else { return false }
        return a == b
    }
}
