// Ported from AiTerm (app/Tests/AiTermCoreTests/HookConfigTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct CodexHooksTests {
    let emdashSettings = """
    {"statusLine": {"type": "command", "command": "/Users/me/.claude/statusline/statusline.py", "padding": 1},
     "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/Users/me/.emdash/hook.sh", "_emdash": true}]}]},
     "model": "opus"}
    """

    @Test func testCodexMergeAppendsOnceAndReplacesOwnBlock() {
        let base = "model = \"gpt-5.6\"\n\n[[hooks.SessionStart]]\nmatcher = \"^startup$\"\n[[hooks.SessionStart.hooks]]\ntype = \"command\"\ncommand = 'python3 ~/.codex/hooks/emdash.py'\n"
        let once = CodexHookConfig.merge(base, hookURL: "http://127.0.0.1:47831")
        #expect(once.hasPrefix(base))
        #expect(once.components(separatedBy: "# >>> shellforge hooks >>>").count == 2)
        #expect(once.contains("[[hooks.PermissionRequest]]") && once.contains("/hook/codex"))
        #expect(once.contains("[[hooks.SubagentStart]]") && once.contains("[[hooks.SubagentStop]]"))
        #expect(!once.contains("PreToolUse"), "the retired synchronous Bash hook is not installed")
        #expect(once.contains("X-Shellforge-Hook: 1") && once.contains("Expect:"))
        #expect(once.contains("X-Shellforge-iTerm-Session: $ITERM_SESSION_ID"))
        #expect(once.contains("[mcp_servers.shellforge_hooks]"))
        #expect(once.contains("url = \"http://127.0.0.1:47831/mcp\""))
        #expect(once.contains("X-Shellforge-iTerm-Session = \"ITERM_SESSION_ID\""))
        let stop = once.components(separatedBy: "[[hooks.Stop]]")[1]
        #expect(stop.contains("type = \"mcp_tool\""))
        #expect(stop.contains("tool = \"post_codex_hook\""))
        #expect(stop.contains("hook_event_name = \"${hook_event_name}\""))
        let twice = CodexHookConfig.merge(once, hookURL: "http://127.0.0.1:9999")
        #expect(twice.components(separatedBy: "# >>> shellforge hooks >>>").count == 2)
        #expect(twice.contains(":9999/hook/codex") && twice.contains(":9999/mcp") && !twice.contains(":47831"))
        #expect(twice.contains("emdash.py"))
    }

    @Test func codexRepairFindsMovedHooksAndPreservesApprovalRecords() throws {
        let moved = """
        [[hooks.SessionStart]]
        matcher = ""
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = 'curl -s -m 2 -X POST -H "X-Shellforge-Hook: 1" --data-binary @- http://127.0.0.1:1/hook/codex'
        [[hooks.SessionStart.hooks]]
        type = "command"
        command = 'keep-me'
        # >>> shellforge hooks >>>
        [mcp_servers.shellforge_hooks]
        url = "http://127.0.0.1:1/mcp"
        [hooks.state."config:session_start:0:1"]
        trusted_hash = "sha256:keep-me"
        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "mcp_tool"
        server = "shellforge_hooks"
        tool = "post_codex_hook"
        # <<< shellforge hooks <<<
        """
        let result = CodexHookConfig.merge(moved, hookURL: "http://127.0.0.1:47831")
        #expect(!result.contains(":1/hook/codex"))
        #expect(result.contains("command = 'keep-me'"))
        #expect(result.contains("[hooks.state.\"config:session_start:0:1\"]\ntrusted_hash = \"sha256:keep-me\""))
        #expect(result.components(separatedBy: "[[hooks.SessionStart]]").count - 1 == 2)
        #expect(result.components(separatedBy: "[[hooks.Stop]]").count - 1 == 1)
        #expect(CodexHookConfig.merge(result, hookURL: "http://127.0.0.1:47831") == result)
    }

    @Test func codexRepairRemovesDuplicateBlocksAndHooksWithMissingMarkers() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        let block = CodexHookConfig.merge(nil, hookURL: "http://127.0.0.1:47831")
        for input in [block + block, block.replacingOccurrences(of: CodexHookConfig.end, with: ""),
                      block.replacingOccurrences(of: CodexHookConfig.begin, with: "")] {
            try input.write(to: config, atomically: true, encoding: .utf8)
            #expect(CodexHooks(home: home, port: 47831).state != .current)
            try CodexHooks(home: home, port: 47831).install()
            let result = try String(contentsOf: config, encoding: .utf8)
            #expect(result.components(separatedBy: "[[hooks.SessionStart]]").count - 1 == 1)
            #expect(result.components(separatedBy: "[[hooks.Stop]]").count - 1 == 1)
            #expect(result.components(separatedBy: "[mcp_servers.shellforge_hooks]").count - 1 == 1)
            #expect(CodexHooks(home: home, port: 47831).state == .current)
        }
    }

    @Test func codexRepairDoesNotInterpretStringsOrCommentsAsOwnedHooks() {
        let foreign = """
        description = '''
        # >>> shellforge hooks >>>
        [[hooks.Stop.hooks]]
        type = "mcp_tool"
        server = "shellforge_hooks"
        tool = "post_codex_hook"
        # <<< shellforge hooks <<<
        '''
        [[hooks.Stop]]
        [[hooks.Stop.hooks]]
        type = "command"
        command = 'echo shellforge'
        # command = 'curl -H "X-Shellforge-Hook: 1" http://127.0.0.1:47831/hook/codex'
        [profiles.keep]
        model = "keep-me"
        """ + "\n"
        let result = CodexHookConfig.merge(foreign, hookURL: "http://127.0.0.1:47831")
        #expect(result.hasPrefix(foreign))
        #expect(CodexHookConfig.merge(result, hookURL: "http://127.0.0.1:47831") == result)
    }

    @Test func codexRepairAcceptsCRLFAndMultilineStringsEndingInQuotes() {
        let block = CodexHookConfig.merge(nil, hookURL: "http://127.0.0.1:1")
        for input in [block.replacingOccurrences(of: "\n", with: "\r\n"),
                      "description = \"\"\"hello\"\"\"\"\n" + block] {
            let result = CodexHookConfig.merge(input, hookURL: "http://127.0.0.1:47831")
            #expect(!result.contains(":1/mcp"))
            #expect(result.components(separatedBy: "[[hooks.Stop]]").count - 1 == 1)
            #expect(CodexHookConfig.merge(result, hookURL: "http://127.0.0.1:47831") == result)
        }
    }

    @Test func codexRepairKeepsForeignChildrenAfterInterveningTables() {
        let input = """
        [[hooks.Stop]]
        matcher = "keep-matcher"
        [[hooks.Stop.hooks]]
        type = "mcp_tool"
        server = "shellforge_hooks"
        tool = "post_codex_hook"
        [hooks.Stop.hooks.input]
        session_id = "old-input"
        # Keep this profile explanation.
        [profiles.fast]
        model = "keep-model"
        [[hooks.Stop.hooks]]
        type = "command"
        command = "keep-command"
        """
        let result = CodexHookConfig.merge(input, hookURL: "http://127.0.0.1:47831")
        #expect(result.contains("[[hooks.Stop]]\nmatcher = \"keep-matcher\""))
        #expect(result.contains("command = \"keep-command\""))
        #expect(result.contains("[profiles.fast]\nmodel = \"keep-model\""))
        #expect(result.contains("# Keep this profile explanation."))
        #expect(!result.contains("old-input"))
        #expect(result.components(separatedBy: "[[hooks.Stop]]").count - 1 == 2)
        #expect(CodexHookConfig.merge(result, hookURL: "http://127.0.0.1:47831") == result)
    }

    @Test func testCodexMergeHandlesEndMarkerBeforeBeginWithoutCrashingAndKeepsUserContent() {
        let corrupted = "keep-me = true\n" + CodexHookConfig.end + "\n" + CodexHookConfig.begin + "\n" + "trailing-line = true\n"
        let merged = CodexHookConfig.merge(corrupted, hookURL: "http://127.0.0.1:47831")
        #expect(merged.contains("keep-me = true"), "non-marker user content before the markers must survive")
        #expect(merged.contains("trailing-line = true"), "non-marker user content after the markers must survive")
        #expect(merged.components(separatedBy: CodexHookConfig.begin).count == 2, "exactly one well-formed block, not two")
        #expect(merged.components(separatedBy: CodexHookConfig.end).count == 2, "exactly one well-formed block, not two")
        #expect(merged.contains("[[hooks.PermissionRequest]]") && merged.contains("/hook/codex"))
    }

    @Test func testCodexMergeStripsOrphanBeginMarkerAndKeepsUserContent() {
        let corrupted = "keep-me = true\n" + CodexHookConfig.begin + "\n" + "trailing-line = true\n"
        let merged = CodexHookConfig.merge(corrupted, hookURL: "http://127.0.0.1:47831")
        #expect(merged.contains("keep-me = true"), "non-marker user content before the orphan marker must survive")
        #expect(merged.contains("trailing-line = true"), "non-marker user content after the orphan marker must survive")
        #expect(merged.components(separatedBy: CodexHookConfig.begin).count == 2, "exactly one well-formed block, not two")
        #expect(merged.components(separatedBy: CodexHookConfig.end).count == 2, "exactly one well-formed block, not two")
    }

    @Test func testClaudeAndCodexInstallersAreIsolatedAndIdempotent() throws {
        let home = TestScratch.root.appendingPathComponent("sf-installers-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let codexURL = home.appendingPathComponent(".codex/config.toml")
        let claudeURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"foreign\"\n".write(to: codexURL, atomically: true, encoding: .utf8)

        try ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh").install()
        let codexBefore = try Data(contentsOf: codexURL)
        let claudeAfterFirstInstall = try Data(contentsOf: claudeURL)
        try ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh").install()
        #expect(try Data(contentsOf: codexURL) == codexBefore)
        #expect(try Data(contentsOf: claudeURL) == claudeAfterFirstInstall)

        try CodexHooks(home: home, port: 47831).install()
        let claudeBefore = try Data(contentsOf: claudeURL)
        let codexAfterFirstInstall = try Data(contentsOf: codexURL)
        try CodexHooks(home: home, port: 47831).install()
        #expect(try Data(contentsOf: claudeURL) == claudeBefore)
        #expect(try Data(contentsOf: codexURL) == codexAfterFirstInstall)
    }

    @Test func testPerHarnessInstallationProbesReadOnlyTheirOwnConfiguration() throws {
        let home = TestScratch.root.appendingPathComponent("sf-probes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let shim = "/Applications/Shellforge.app/shim.sh"

        #expect(ClaudeHooks(home: home, port: 47831, shimPath: shim).state != .current)
        #expect(CodexHooks(home: home, port: 47831).state != .current)
        try ClaudeHooks(home: home, port: 47831, shimPath: shim).install()
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: shim).state == .current)
        #expect(CodexHooks(home: home, port: 47831).state != .current)
        try CodexHooks(home: home, port: 47831).install()
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: shim).state == .current)
        #expect(CodexHooks(home: home, port: 47831).state == .current)
    }

    func temporaryHome() throws -> URL {
        let home = TestScratch.root.appendingPathComponent("sf-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        return home
    }

    /// Dotfile managers keep `settings.json` and `config.toml` as symlinks into a repository. An
    /// atomic write replaced the link with a regular file, silently forking the user's config.

    @Test func symlinkedConfigFilesStaySymlinksAndTheirTargetsAreMerged() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let dotfiles = home.appendingPathComponent("dotfiles")
        try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let claudeTarget = dotfiles.appendingPathComponent("claude-settings.json")
        let codexTarget = dotfiles.appendingPathComponent("codex-config.toml")
        try Data(emdashSettings.utf8).write(to: claudeTarget)
        try "model = \"foreign\"\n".write(to: codexTarget, atomically: true, encoding: .utf8)
        let claudeLink = home.appendingPathComponent(".claude/settings.json"), codexLink = home.appendingPathComponent(".codex/config.toml")
        try fm.createSymbolicLink(at: claudeLink, withDestinationURL: claudeTarget)
        try fm.createSymbolicLink(at: codexLink, withDestinationURL: codexTarget)

        try ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh").install()
        try CodexHooks(home: home, port: 47831).install()

        #expect(try fm.destinationOfSymbolicLink(atPath: claudeLink.path) == claudeTarget.path)
        #expect(try fm.destinationOfSymbolicLink(atPath: codexLink.path) == codexTarget.path)
        #expect(ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh").state == .current)
        #expect(try String(contentsOf: codexTarget, encoding: .utf8).contains(CodexHookConfig.begin))
        // The backup is a copy of what the link pointed at, not a second link to the merged file.
        for (link, original) in [(claudeLink, Data(emdashSettings.utf8)), (codexLink, Data("model = \"foreign\"\n".utf8))] {
            let backup = link.appendingPathExtension("shellforge-backup")
            #expect(try fm.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType == .typeRegular)
            #expect(try Data(contentsOf: backup) == original)
        }
    }

    /// A link whose target is gone is not "no settings yet": writing would replace the link with a
    /// regular file and cut the user's config off from the repository it lives in.

    @Test func aDanglingSymlinkIsLeftAloneAndReported() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        let missing = home.appendingPathComponent("dotfiles/gone")
        let claudeLink = home.appendingPathComponent(".claude/settings.json"), codexLink = home.appendingPathComponent(".codex/config.toml")
        try fm.createSymbolicLink(atPath: claudeLink.path, withDestinationPath: missing.appendingPathExtension("json").path)
        try fm.createSymbolicLink(atPath: codexLink.path, withDestinationPath: missing.appendingPathExtension("toml").path)

        let claudeError = #expect(throws: HookInstallError.self) {
            try ClaudeHooks(home: home, port: 47831, shimPath: "/Applications/Shellforge.app/shim.sh").install()
        }
        let codexError = #expect(throws: HookInstallError.self) { try CodexHooks(home: home, port: 47831).install() }
        #expect(claudeError?.localizedDescription
                == "Refusing to change ~/.claude/settings.json: it links to \(missing.appendingPathExtension("json").path), which does not exist.")
        #expect(codexError?.localizedDescription
                == "Refusing to change ~/.codex/config.toml: it links to \(missing.appendingPathExtension("toml").path), which does not exist.")
        for (link, ext) in [(claudeLink, "json"), (codexLink, "toml")] {
            #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == missing.appendingPathExtension(ext).path)
            #expect(!fm.fileExists(atPath: missing.appendingPathExtension(ext).path), "the missing target is not created")
            #expect(!fm.fileExists(atPath: link.appendingPathExtension("shellforge-backup").path))
        }
    }

    /// `JSONSerialization` escapes `/` by default, so every path in the user's file came back as `\/`.

    @Test func aCodexConfigThatIsNotUTF8IsLeftAloneAndReported() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        let latin1 = Data("name = \"caf".utf8) + Data([0xE9]) + Data("\"\n".utf8)
        try latin1.write(to: config)

        #expect(throws: HookInstallError.self) { try CodexHooks(home: home, port: 47831).install() }
        #expect(try Data(contentsOf: config) == latin1)
    }

    /// Whatever the user (or `codex` itself) appends after Shellforge's block is theirs. The block
    /// still reads as current, and a repair rewrites it where it stands instead of moving it last.

    @Test func codexContentAfterTheBlockNeitherOutdatesNorMovesIt() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        let installed = CodexHookConfig.merge("model = \"gpt-5.6\"\n", hookURL: "http://127.0.0.1:47831")
        let text = installed + "\n[profiles.fast]\nmodel = \"gpt-5.6-mini\"\n"
        try text.write(to: config, atomically: true, encoding: .utf8)

        #expect(CodexHooks(home: home, port: 47831).state == .current)
        try CodexHooks(home: home, port: 47831).install()
        #expect(try String(contentsOf: config, encoding: .utf8) == text)

        #expect(CodexHooks(home: home, port: 9999).state != .current)
        let repaired = CodexHookConfig.merge(text, hookURL: "http://127.0.0.1:9999")
        #expect(repaired == text.replacingOccurrences(of: "127.0.0.1:47831", with: "127.0.0.1:9999"))
    }

    /// An upgrade must not wait for Settings' Install or Repair to keep the user's status line
    /// showing: nothing reports an install with only the JSON record as out of date.

    @Test(arguments: [
        ("hooks.Stop = [{ matcher = \"\" }]\n", "hooks.Stop"),
        ("[hooks]\nStop = [{ matcher = \"\" }]\n", "hooks.Stop"),
        ("[hooks]\nSessionStart.matcher = \"x\"\n", "hooks.SessionStart"),
        ("hooks = { Stop = [] }\n", "hooks"),
        ("[hooks.PermissionRequest]\nmatcher = \"\"\n", "hooks.PermissionRequest"),
        ("\"hooks\" . 'UserPromptSubmit' = []\n", "hooks.UserPromptSubmit"),
    ])
    func aCodexEventSetInAFormTOMLCannotExtendIsRefused(text: String, key: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try text.write(to: config, atomically: true, encoding: .utf8)
        let driver = CodexHooks(home: home, port: 47831)

        #expect(driver.probe() == HookProbe(state: .unreadable,
                                              explanation: "~/.codex/config.toml sets \(key) in a form Shellforge cannot merge."))
        #expect(throws: HookInstallError.refused(path: "~/.codex/config.toml", reason: "sets \(key) in a form Shellforge cannot merge")) {
            try driver.install()
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == text)
    }

    /// Another event, or Shellforge's own array-of-tables entries, are no conflict.

    @Test(arguments: ["[hooks]\nPreToolUse = []\n", "hooks.PostToolUse = []\n", "[[hooks.Stop]]\nmatcher = \"x\"\n[hooks.Stop.extra]\na = 1\n"])
    func otherHookAssignmentsStillMerge(text: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        try text.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        let driver = CodexHooks(home: home, port: 47831)
        #expect(driver.state == .missing)
        try driver.install()
        #expect(driver.state == .current)
    }

    @Test(arguments: [
        ("[hooks.Stop.hooks]\ntype = \"command\"\n", "hooks.Stop"),
        ("[hooks.Stop.x]\na = 1\n", "hooks.Stop"),
        ("[[hooks.SessionStart.hooks]]\ntype = \"command\"\n", "hooks.SessionStart"),
    ])
    func aSubTableThatImpliesTheEventIsATableIsRefused(text: String, key: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/config.toml")
        try text.write(to: config, atomically: true, encoding: .utf8)
        let driver = CodexHooks(home: home, port: 47831)
        #expect(CodexHookConfig.conflict(in: text) == key)
        #expect(throws: HookInstallError.refused(path: "~/.codex/config.toml", reason: "sets \(key) in a form Shellforge cannot merge")) {
            try driver.install()
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == text)
    }

    @Test func aSubTableAfterItsArrayParentIsNoConflict() {
        #expect(CodexHookConfig.conflict(in: "[[hooks.Stop]]\nmatcher = \"\"\n[hooks.Stop.x]\na = 1\n[[hooks.Stop.hooks]]\n") == nil)
        #expect(CodexHookConfig.conflict(in: "[hooks.PreToolUse.x]\na = 1\n") == nil, "an event Shellforge does not manage")
    }

    @Test func bracketsInStringsAndCommentsAreBalanced() {
        #expect(TOMLStatements.isBalanced("a = \"]\"\nb = '['\n# ] [ {\nc = [ [1], {x = 2} ]\n[t]\n[[u]]\nd = \"\"\"]\n\"\"\"\n"))
        #expect(!TOMLStatements.isBalanced("a = 1]\n"))
        #expect(!TOMLStatements.isBalanced("a = [1\n"))
        #expect(!TOMLStatements.isBalanced("a = \"open\n"))
    }

    /// AiTerm's block and MCP server stay as they are; Shellforge's block goes beside them, and
    /// neither is taken for the other's on a repair.
    @Test func aitermsHooksStayBesideShellforges() throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let aiterm = """
        model = "gpt-5"

        # >>> aiterm hooks >>>
        [mcp_servers.aiterm_hooks]
        url = "http://127.0.0.1:47821/mcp"

        [mcp_servers.aiterm_hooks.http_headers]
        X-AiTerm-Hook = "1"

        [[hooks.Stop]]
        type = "mcp_tool"
        server = "aiterm_hooks"
        tool = "post_codex_hook"
        # <<< aiterm hooks <<<
        """
        let url = home.appendingPathComponent(CodexHooks.configPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try aiterm.write(to: url, atomically: true, encoding: .utf8)
        let hooks = CodexHooks(home: home, port: 47831)
        #expect(hooks.probe().state == .missing)
        try hooks.install()
        try hooks.install()   // a second install changes nothing
        #expect(hooks.probe().state == .current)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains(aiterm))
        #expect(text.components(separatedBy: "# >>> shellforge hooks >>>").count == 2)
        #expect(text.contains("[mcp_servers.shellforge_hooks]") && text.contains("http://127.0.0.1:47831/mcp"))
    }

    @Test(arguments: ["[a]\nx = 1]\n", "[a]\nx = [1, 2\n", "x = { a = 1 \n[b]\n", "x = 1 }\n"])
    func unbalancedTOMLIsRefusedByBothTOMLDrivers(text: String) throws {
        let home = try temporaryHome(); defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent(".codex/config.toml")
        try text.write(to: codex, atomically: true, encoding: .utf8)
        #expect(CodexHooks(home: home, port: 47831).probe()
                == HookProbe(state: .unreadable, explanation: "~/.codex/config.toml cannot be parsed."))
        #expect(throws: HookInstallError.refused(path: "~/.codex/config.toml", reason: "cannot be parsed")) {
            try CodexHooks(home: home, port: 47831).install()
        }
        #expect(try String(contentsOf: codex, encoding: .utf8) == text)

        let grokHome = try temporaryHome(); defer { try? FileManager.default.removeItem(at: grokHome) }
        let grok = grokHome.appendingPathComponent(".grok/config.toml")
        try FileManager.default.createDirectory(at: grok.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: grok, atomically: true, encoding: .utf8)
        let driver = GrokHooks(home: grokHome, port: 47831, shimPath: "/A/shellforge-grok-statusline.sh")
        #expect(driver.probe() == HookProbe(state: .unreadable, explanation: "~/.grok/config.toml cannot be parsed."))
        #expect(throws: HookInstallError.refused(path: "~/.grok/config.toml", reason: "cannot be parsed")) { try driver.install() }
        #expect(try String(contentsOf: grok, encoding: .utf8) == text)
        #expect(!FileManager.default.fileExists(atPath: GrokHooksFile.url(home: grokHome).path), "nothing written first")
    }

}
