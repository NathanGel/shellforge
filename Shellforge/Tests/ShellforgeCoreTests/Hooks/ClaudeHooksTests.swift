// Ported from AiTerm (app/Tests/AiTermCoreTests/HookConfigTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ClaudeHooksTests {
    let emdashSettings = """
    {"statusLine": {"type": "command", "command": "/Users/me/.claude/statusline/statusline.py", "padding": 1},
     "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/Users/me/.emdash/hook.sh", "_emdash": true}]}]},
     "model": "opus"}
    """

    @Test func testClaudeMergeKeepsForeignEntriesWrapsStatusLineAndIsIdempotent() throws {
        let url = "http://127.0.0.1:47831/hook/claude"
        let (once, original) = try ClaudeSettings.merge(Data(emdashSettings.utf8), hookURL: url, shimPath: "/Applications/Shellforge.app/shim.sh")
        let obj = try JSONSerialization.jsonObject(with: once) as! [String: Any]
        let hooks = obj["hooks"] as! [String: [[String: Any]]]
        #expect(hooks["Stop"]!.count == 2, "Emdash entry kept, ours added")
        #expect(Set(hooks.keys) == ["SessionStart", "PostModelSwitch", "UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop", "Notification", "PermissionRequest"])
        #expect(hooks.values.allSatisfy { $0.allSatisfy { entry in
            (entry["hooks"] as! [[String: Any]]).allSatisfy { $0["_shellforge"] == nil || $0["async"] as? Bool == true }
        } }, "every Shellforge hook is telemetry, so none may hold the agent up")
        #expect(((hooks["Notification"]![0]["hooks"] as! [[String: Any]])[0]["url"] as? String) == url)
        #expect((((hooks["Notification"]![0]["hooks"] as! [[String: Any]])[0]["headers"] as! [String: String])["X-Shellforge-Hook"]) == "1")
        #expect((obj["statusLine"] as! [String: Any])["command"] as? String == "/Applications/Shellforge.app/shim.sh")
        #expect((obj["statusLine"] as! [String: Any])["padding"] as? Int == 1)
        #expect(original?["command"] as? String == "/Users/me/.claude/statusline/statusline.py")
        #expect(obj["model"] as? String == "opus")
        let (twice, originalAgain) = try ClaudeSettings.merge(once, hookURL: url, shimPath: "/Applications/Shellforge.app/shim.sh")
        #expect(try JSONSerialization.jsonObject(with: twice) as! NSDictionary == obj as NSDictionary)
        #expect(originalAgain == nil, "shim already installed: nothing to save")
    }

    @Test func testClaudeMergeFromEmptyFile() throws {
        let (data, original) = try ClaudeSettings.merge(nil, hookURL: "u", shimPath: "s")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((obj["hooks"] as! [String: Any]).count == 8)
        #expect(original == nil)
    }

    @Test func testTelemetryReinstallPreservesACustomDisplayButDoesNotReviveARemovedOne() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sf-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"my-statusline"}}"#.utf8).write(to: settings)
        let shim = "/Applications/Shellforge.app/shellforge-claude-statusline.sh"
        try ClaudeHooks(home: home, port: 47831, shimPath: shim).install()
        let command = ShellforgePaths.statusLineOriginalURL(home: home)
        #expect(try String(contentsOf: command, encoding: .utf8) == "my-statusline", "the shim reads the command as plain text")
        try ClaudeHooks(home: home, port: 47831, shimPath: shim).install()
        #expect(try String(contentsOf: command, encoding: .utf8) == "my-statusline")
        // The record goes when the user's status line does.
        try Data("{}".utf8).write(to: settings)
        try ClaudeHooks(home: home, port: 47831, shimPath: shim).install()
        #expect(!FileManager.default.fileExists(atPath: command.path))
        #expect(ClaudeSettings.statusLineIsInstalled(try Data(contentsOf: settings), shimPath: shim, isRunnable: { _ in true }))
    }

    /// The shim posts to the port in `hook-port`, so Install writes it, and settings that are
    /// current without it are outdated until a Repair does.
    @Test func installRecordsTheShimsPort() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let shim = "/Applications/Shellforge.app/shellforge-claude-statusline.sh"
        let driver = ClaudeHooks(home: home, port: 50123, shimPath: shim)
        try driver.install()
        #expect(try String(contentsOf: ShellforgePaths.hookPortURL(home: home), encoding: .utf8) == "50123\n")
        #expect(driver.state == .current)

        try FileManager.default.removeItem(at: ShellforgePaths.hookPortURL(home: home))
        #expect(driver.state == .outdated, "the shim has no port to post to: Repair writes it")
        try Data("47831\n".utf8).write(to: ShellforgePaths.hookPortURL(home: home))
        #expect(driver.state == .outdated, "another port than the hooks' own")
        try driver.install()
        #expect(driver.state == .current)
    }

    /// AiTerm once installed `PreToolUse` as a synchronous Bash hook. A merge takes out only our
    /// own entry — a foreign hook sharing the entry or the event stays — and until that repair has
    /// run, the install reads as outdated rather than current.

    @Test func testRetiredPreToolUseHookIsRemovedButForeignOnesStay() throws {
        let ours: [String: Any] = ["type": "http", "url": "http://127.0.0.1:47831/hook/claude", "_shellforge": true, "timeout": 3]
        let foreign: [String: Any] = ["type": "command", "command": "/usr/local/bin/guard.sh"]
        let old = try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [
            ["matcher": "Bash", "hooks": [ours]],
            ["matcher": "Bash", "hooks": [ours, foreign]],
        ]]])
        let (merged, _) = try ClaudeSettings.merge(old, hookURL: "http://127.0.0.1:47831/hook/claude", shimPath: "s")
        let hooks = (try JSONSerialization.jsonObject(with: merged) as! [String: Any])["hooks"] as! [String: Any]
        let preTool = hooks["PreToolUse"] as! [[String: Any]]
        #expect(preTool.count == 1)
        #expect((preTool[0]["hooks"] as! [[String: Any]]).map { $0["command"] as? String } == ["/usr/local/bin/guard.sh"])

        let onlyOurs = try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [["matcher": "Bash", "hooks": [ours]]]]])
        let (cleaned, _) = try ClaudeSettings.merge(onlyOurs, hookURL: "u", shimPath: "s")
        #expect(((try JSONSerialization.jsonObject(with: cleaned) as! [String: Any])["hooks"] as! [String: Any])["PreToolUse"] == nil)

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sf-home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let shim = "/Applications/Shellforge.app/shellforge-claude-statusline.sh"
        try ClaudeHooks(home: home, port: 47831, shimPath: shim).install()
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: shim).state == .current)
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        var withRetired = obj["hooks"] as! [String: Any]
        withRetired["PreToolUse"] = [["matcher": "Bash", "hooks": [ours]]]
        obj["hooks"] = withRetired
        try JSONSerialization.data(withJSONObject: obj).write(to: settings)
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: shim).state != .current)
        try ClaudeHooks(home: home, port: 47831, shimPath: shim).install()
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: shim).state == .current)
    }

    @Test func claudeRepairReplacesStaleAndDuplicateHooksButKeepsMixedForeignHooks() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try ClaudeHooks(home: home, port: 47831, shimPath: "s").install()
        var obj = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        var hooks = obj["hooks"] as! [String: [[String: Any]]]
        let current = hooks["Stop"]![0]
        let stale: [String: Any] = ["_shellforge": true, "type": "http", "url": "http://127.0.0.1:1/hook/claude", "async": false]
        let foreign: [String: Any] = ["type": "command", "command": "keep-me"]
        hooks["Stop"] = [current, ["matcher": "Bash", "hooks": [stale, foreign]], current]
        obj["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: obj).write(to: settings)
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: "s").state != .current)
        try ClaudeHooks(home: home, port: 9999, shimPath: "s").install()
        let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let stops = (repaired["hooks"] as! [String: [[String: Any]]])["Stop"]!
        let owned = stops.flatMap { $0["hooks"] as! [[String: Any]] }.filter { $0["_shellforge"] as? Bool == true }
        #expect(owned.count == 1)
        #expect(owned.first?["url"] as? String == "http://127.0.0.1:9999/hook/claude")
        #expect(owned.first?["async"] as? Bool == true)
        let mixed = try #require(stops.first { $0["matcher"] as? String == "Bash" })
        #expect((mixed["hooks"] as! [[String: Any]]) as NSArray == [foreign] as NSArray)
        #expect(ClaudeHooks(home: home, port: 9999, shimPath: "s").state == .current)
    }

    @Test func testClaudeMergeThrowsOnUnparsableSettingsInsteadOfReplacingIt() {
        let malformedError = #expect(throws: (any Error).self) {
            _ = try ClaudeSettings.merge(Data("{nope".utf8), hookURL: "u", shimPath: "s")
        }
        #expect(malformedError as? ClaudeSettings.Unmergeable == ClaudeSettings.Unmergeable(reason: "is not a JSON object"),
                "malformed JSON must raise a typed error, not fall back to an empty object")

        let nonObjectError = #expect(throws: (any Error).self) {
            _ = try ClaudeSettings.merge(Data("[]".utf8), hookURL: "u", shimPath: "s")
        }
        #expect(nonObjectError as? ClaudeSettings.Unmergeable == ClaudeSettings.Unmergeable(reason: "is not a JSON object"),
                "a JSON array is not a settings object and must raise a typed error")
    }

    @Test func testClaudeMergeFromEmptyDataStillStartsEmpty() throws {
        let (data, original) = try ClaudeSettings.merge(Data(), hookURL: "u", shimPath: "s")
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((obj["hooks"] as! [String: Any]).count == ClaudeSettings.events.count, "empty (as opposed to malformed) settings data still merges from an empty object")
        #expect(original == nil)
    }

    @Test func testClaudeMergeRepointsAMovedShimWithoutRecordingItAsAForeignOriginal() throws {
        let settingsWithOldShimPath = """
        {"statusLine": {"type": "command", "command": "/old/AIterm.app/Contents/Resources/shellforge-claude-statusline.sh", "padding": 2}}
        """
        let newShimPath = "/new/Shellforge.app/Contents/Resources/shellforge-claude-statusline.sh"
        let (data, original) = try ClaudeSettings.merge(Data(settingsWithOldShimPath.utf8), hookURL: "http://127.0.0.1:47831/hook/claude", shimPath: newShimPath)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect((obj["statusLine"] as! [String: Any])["command"] as? String == newShimPath, "the moved bundle's shim path must be repointed to the new location")
        #expect((obj["statusLine"] as! [String: Any])["padding"] as? Int == 2, "padding from the old shim entry is preserved")
        #expect(original == nil, "the old shim path is recognised as ours by filename and must never be saved as a foreign original (that would make the shim recurse into itself)")
    }

    @Test func testInstallWritesOriginalStatusLineBeforeSettingsFileSurvivesASettingsWriteFailure() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sf-home-\(UUID().uuidString)")
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try Data("""
        {"statusLine": {"type": "command", "command": "/Users/me/.claude/statusline/statusline.py", "padding": 1}}
        """.utf8).write(to: settingsURL)
        // Make the .claude directory read-only so writing (and backing up) settings.json fails,
        // while Library/Application Support/AiTerm (a sibling tree) stays writable. If the
        // installer still writes statusline-original.cmd first, it survives the failed
        // settings.json write below; if it wrote settings.json first, the original would be lost.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: claudeDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeDir.path)
            try? FileManager.default.removeItem(at: home)
        }

        #expect(throws: (any Error).self) {
            try ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh").install()
        }

        let saved = try String(contentsOf: ShellforgePaths.statusLineOriginalURL(home: home), encoding: .utf8)
        #expect(saved == "/Users/me/.claude/statusline/statusline.py", "the original status line must have been saved before the (failing) settings.json write")
    }

    /// The shim is the only channel Claude usage can arrive through — Claude Code hands out
    /// `rate_limits` to the status line command and nowhere else — and anything may take it back
    /// out of `settings.json` (a `/statusline` change, another tool, the user). A one-shot
    /// "installed" flag therefore cannot be trusted; every launch has to look at the file.

    @Test func testAMissingOrForeignStatusLineIsDetected() {
        let shim = "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-claude-statusline.sh"
        let ours = Data(#"{"statusLine":{"type":"command","command":"\#(shim)"}}"#.utf8)
        #expect(ClaudeSettings.statusLineIsInstalled(ours, shimPath: shim, isRunnable: { _ in true }))
        #expect(!ClaudeSettings.statusLineIsInstalled(Data(#"{"hooks":{}}"#.utf8), shimPath: shim),
                "statusLine deleted outright — the usage feed is dead and the footer must say so")
        #expect(!ClaudeSettings.statusLineIsInstalled(Data(#"{"statusLine":{"type":"command","command":"/Users/me/.claude/statusline/statusline.py"}}"#.utf8), shimPath: shim),
                "someone else's status line is not ours")
        #expect(!ClaudeSettings.statusLineIsInstalled(nil, shimPath: shim))
        #expect(!ClaudeSettings.statusLineIsInstalled(Data("not json".utf8), shimPath: shim))
    }

    /// The bundle can move (a rebuild into another directory, a drag to /Applications) without the
    /// shim ceasing to be ours — `ClaudeSettings.merge` already repoints it by filename rather than
    /// treating it as a foreign original, and the launch check has to agree, or every move would
    /// report the feed as broken. What it must not agree with is a path nothing answers at.

    @Test func testTheShimIsStillOursAfterTheBundleMovesButNotAfterItVanishes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiterm-shim-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let moved = dir.appendingPathComponent("shellforge-claude-statusline.sh")
        try "#!/bin/zsh\nexit 0\n".write(to: moved, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: moved.path)
        let settings = Data(#"{"statusLine":{"type":"command","command":"\#(moved.path)"}}"#.utf8)
        let shim = "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-claude-statusline.sh"
        #expect(ClaudeSettings.statusLineIsInstalled(settings, shimPath: shim))
        try FileManager.default.removeItem(at: moved)
        #expect(!ClaudeSettings.statusLineIsInstalled(settings, shimPath: shim),
                "a command Claude Code can only fail to exec is not an installed status line")
    }

    /// A user's machine: macOS ran the quarantined bundle from an AppTranslocation mount,
    /// the installer wrote that ephemeral path into settings.json, and the mount died with the
    /// app. Claude Code got exit 127 on every tick while the footer reported the feed as healthy,
    /// because the filename still matched.

    @Test func testATranslocatedStatusLineCommandIsReportedAsDisconnected() {
        let gone = "/private/var/folders/t8/251d/T/AppTranslocation/729DBBB2-661E/d/Shellforge 2.app/Contents/Resources/hooks/shellforge-claude-statusline.sh"
        #expect(!ClaudeSettings.statusLineIsInstalled(
            Data(#"{"statusLine":{"type":"command","command":"\#(gone)"}}"#.utf8),
            shimPath: "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-claude-statusline.sh"))
    }

    @Test func testATranslocatedBundleIsRecognisedByItsPath() {
        #expect(BundleLocation.isTranslocated("/private/var/folders/t8/251d/T/AppTranslocation/729DBBB2-661E/d/Shellforge 2.app/Contents/Resources"))
        #expect(!BundleLocation.isTranslocated("/Applications/Shellforge.app/Contents/Resources"))
        #expect(!BundleLocation.isTranslocated("/Users/me/Sites/Shellforge/build/Shellforge.app/Contents/Resources"))
    }

    func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sf-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        return home
    }

    /// Dotfile managers keep `settings.json` and `config.toml` as symlinks into a repository. An
    /// atomic write replaced the link with a regular file, silently forking the user's config.

    @Test func mergedSettingsKeepSlashesUnescaped() throws {
        let (merged, _) = try ClaudeSettings.merge(Data(emdashSettings.utf8), hookURL: "http://127.0.0.1:47831/hook/claude", shimPath: "/Applications/Shellforge.app/shim.sh")
        let text = try #require(String(data: merged, encoding: .utf8))
        #expect(text.contains(#""/Users/me/.emdash/hook.sh""#))
        #expect(!text.contains(#"\/"#))
    }

    /// Another tool's formatting — compact, escaped slashes, a float that `JSONSerialization` would
    /// print as `1.1000000000000001` — is not a reason to rewrite a file that already says the same.

    @Test func anAlreadyCorrectFileIsNotRewrittenOrBackedUp() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let shim = "/Applications/Shellforge.app/shim.sh"
        let settings = home.appendingPathComponent(".claude/settings.json")
        let (merged, _) = try ClaudeSettings.merge(nil, hookURL: "http://127.0.0.1:47831/hook/claude", shimPath: shim)
        var obj = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        obj["model"] = "opus"
        let compact = try JSONSerialization.data(withJSONObject: obj)
        let foreign = String(data: compact, encoding: .utf8)!.replacingOccurrences(of: #""model":"opus""#, with: #""model":"opus","ratio":1.1"#)
        try Data(foreign.utf8).write(to: settings)

        try ClaudeHooks(home: home, port: 47831, shimPath: shim).install()
        #expect(try String(contentsOf: settings, encoding: .utf8) == foreign)
        #expect(!FileManager.default.fileExists(atPath: settings.appendingPathExtension("shellforge-backup").path))
    }

    /// An unreadable file is not a missing one: merging "nothing" and writing the result would
    /// replace the user's settings with AiTerm's entries alone.

    @Test func anUnreadableSettingsFileIsLeftAloneAndReported() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let settings = home.appendingPathComponent(".claude/settings.json")
        try Data(emdashSettings.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: settings.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path) }

        #expect(throws: HookInstallError.self) {
            try ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh").install()
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: settings.path)
        #expect(try Data(contentsOf: settings) == Data(emdashSettings.utf8))
    }

    @Test func aStatusLineNamingAShimThatNoLongerRunsIsOutdatedNotCurrent() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let gone = "/old/Shellforge.app/Contents/Resources/hooks/shellforge-claude-statusline.sh"
        let now = "/new/Shellforge.app/Contents/Resources/hooks/shellforge-claude-statusline.sh"
        try ClaudeHooks(home: home, port: 47831, shimPath: gone).install()
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: gone).state == .current)

        let moved = ClaudeHooks(home: home, port: 47831, shimPath: now)
        #expect(moved.state == .outdated)
        try moved.install()
        #expect(moved.state == .current, "Repair repoints it")
    }

    /// A shim that still runs from another place is a working feed: the card agrees with the footer.

    @Test func aStatusLineNamingAnotherShimThatStillRunsStaysCurrent() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = home.appendingPathComponent("shellforge-claude-statusline.sh")
        try "#!/bin/zsh\nexit 0\n".write(to: elsewhere, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: elsewhere.path)
        try ClaudeHooks(home: home, port: 47831, shimPath: elsewhere.path).install()
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: "/new/Shellforge.app/hooks/shellforge-claude-statusline.sh").state == .current)
    }

    private func refusal(_ settings: String, key: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/settings.json")
        try settings.write(to: file, atomically: true, encoding: .utf8)
        let driver = ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh")
        let reason = "sets \(key) in a form Shellforge cannot merge"

        #expect(driver.probe() == HookProbe(state: .unreadable, explanation: "~/.claude/settings.json \(reason)."))
        #expect(throws: HookInstallError.refused(path: "~/.claude/settings.json", reason: reason)) { try driver.install() }
        #expect(try String(contentsOf: file, encoding: .utf8) == settings, "refused means untouched")
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("shellforge-backup").path))
    }

    @Test func aHooksValueThatIsNotAnObjectIsRefusedNotReplaced() throws {
        try refusal(#"{"hooks": ["something"], "model": "opus"}"#, key: "hooks")
    }

    @Test func anEventThatIsNotAnArrayOfObjectsIsRefusedNotReplaced() throws {
        try refusal(#"{"hooks": {"Stop": "echo done"}}"#, key: "hooks.Stop")
    }

    /// One malformed element used to void the whole array, Emdash's valid entries with it.

    @Test func aMalformedElementBesideEmdashsEntryIsRefusedNotDropped() throws {
        try refusal(#"{"hooks": {"Notification": [{"matcher": "", "hooks": [{"type": "command", "command": "/e/hook.sh", "_emdash": true}]}, 7]}}"#,
                    key: "hooks.Notification")
    }

    @Test func aStatusLineThatIsNotAnObjectIsRefusedNotReplaced() throws {
        try refusal(#"{"statusLine": "~/bin/line.sh"}"#, key: "statusLine")
    }

    /// JSON's `null` says the key is unset, which is how a tool that clears a value writes it: the
    /// merge fills it in as it would a missing key, rather than refusing the file.

    @Test(arguments: [#"{"hooks": null, "model": "opus"}"#, #"{"hooks": {"Stop": null}}"#, #"{"statusLine": null}"#])
    func aNullIsAnAbsentKeyNotARefusal(_ settings: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let file = home.appendingPathComponent(".claude/settings.json")
        try settings.write(to: file, atomically: true, encoding: .utf8)
        let driver = ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh")

        #expect(driver.probe() == HookProbe(.missing))
        try driver.install()
        #expect(driver.probe() == HookProbe(.current))
        let support = home.appendingPathComponent("Library/Application Support/AiTerm")
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("statusline-original.cmd").path),
                "a null status line is no original to keep")
    }

    @Test func anEventShellforgeDoesNotManageIsNeverARefusal() throws {
        let (data, _) = try ClaudeSettings.merge(
            Data(#"{"hooks": {"PostToolUse": "whatever"}}"#.utf8), hookURL: "u", shimPath: "s")
        let hooks = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["hooks"] as? [String: Any])
        #expect(hooks["PostToolUse"] as? String == "whatever")
    }

    /// Only `type` and `command` are ours to set; whatever else the user or a newer Claude Code
    /// put on the status line stays, whether it was theirs or our shim at an old path.

    @Test func repointingTheStatusLineKeepsItsOtherKeys() throws {
        let theirs = #"{"statusLine": {"type": "command", "command": "/u/line.py", "padding": 3, "refreshInterval": 5}}"#
        let (data, original) = try ClaudeSettings.merge(Data(theirs.utf8), hookURL: "u", shimPath: "/n/shim.sh")
        let line = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["statusLine"] as? [String: Any])
        #expect(line["command"] as? String == "/n/shim.sh" && line["type"] as? String == "command")
        #expect(line["padding"] as? Int == 3 && line["refreshInterval"] as? Int == 5)
        #expect(original?["command"] as? String == "/u/line.py")

        let moved = #"{"statusLine": {"type": "command", "command": "/old/shellforge-claude-statusline.sh", "refreshInterval": 5}}"#
        let (again, none) = try ClaudeSettings.merge(Data(moved.utf8), hookURL: "u", shimPath: "/n/shellforge-claude-statusline.sh")
        let repointed = try #require((try JSONSerialization.jsonObject(with: again) as? [String: Any])?["statusLine"] as? [String: Any])
        #expect(repointed["refreshInterval"] as? Int == 5 && repointed["padding"] as? Int == 0)
        #expect(none == nil)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// The user's machine today: AiTerm's hooks and its shim are already in settings.json.
    /// Shellforge's go beside them, its shim keeps AiTerm's as the original it runs, and each
    /// app's entries stay the other's.
    @Test func aitermsHooksStayBesideShellforges() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let aitermShim = "/Applications/AiTerm.app/Contents/Resources/hooks/claude-statusline-shim.sh"
        let aiterm: [String: Any] = [
            "hooks": ["Stop": [["hooks": [["type": "http", "url": "http://127.0.0.1:47821/hook/claude",
                                           "headers": ["X-AiTerm-Hook": "1"], "timeout": 3, "async": true, "_aiterm": true]]]]],
            "statusLine": ["type": "command", "command": aitermShim],
        ]
        try write(aiterm, to: home.appendingPathComponent(ClaudeHooks.settingsPath))
        let shim = "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-claude-statusline.sh"
        let hooks = ClaudeHooks(home: home, port: 47831, shimPath: shim)
        #expect(hooks.probe().state == .missing)
        try hooks.install()
        #expect(hooks.probe().state == .current)
        let settings = try read(home.appendingPathComponent(ClaudeHooks.settingsPath))
        let stop = try #require((settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let urls = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["url"] as? String }
        #expect(Set(urls) == ["http://127.0.0.1:47821/hook/claude", "http://127.0.0.1:47831/hook/claude"])
        #expect((settings["statusLine"] as? [String: Any])?["command"] as? String == shim)
        let original = try String(contentsOf: ShellforgePaths.statusLineOriginalURL(home: home), encoding: .utf8)
        #expect(original == aitermShim)
    }
}
