// Ported from AiTerm (app/Tests/AiTermCoreTests/AgentCommandTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeTestSupport
import Foundation
@testable import ShellforgeCore

@Suite struct AgentCommandTests {
    let wt = TestScratch.root.appendingPathComponent("wt-\(UUID().uuidString)").path
    /// git with no user configuration, for the exclude file; a folder that is no repository leaves it be.
    let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1"],
                                                         source: .loginShell("/bin/sh")) }

    @Test func testShellQuote() {
        #expect(AgentCommand.shellQuote("plain") == "'plain'")
        #expect(AgentCommand.shellQuote("it's \"x\" $HOME") == #"'it'\''s "x" $HOME'"#)
    }

    @Test func testClaudeAndCodexCommands() throws {
        #expect(try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: "high", prompt: "/plan fix it", worktreePath: wt, launcher: launcher) == "claude --model opus --effort high '/plan fix it'")
        #expect(try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: nil, worktreePath: wt, launcher: launcher) == "claude --model opus")
        #expect(try AgentCommand.build(agent: AgentPresets.codex, model: "gpt-5.6", reasoning: "medium", prompt: "review", worktreePath: wt, launcher: launcher) == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6 -c model_reasoning_effort=medium 'review'")
    }

    @Test func grokCommand() {
        #expect(AgentCommand.previewCommand(agent: AgentPresets.grok, model: "grok-4.7", reasoning: "high", prompt: "fix it")
                == "grok -m grok-4.7 --reasoning-effort high 'fix it'")
        #expect(AgentCommand.previewCommand(agent: AgentPresets.grok, model: "grok-4.5", reasoning: nil, prompt: nil)
                == "grok -m grok-4.5")
    }

    @Test func testPiCommandUsesQualifiedModelAndThinking() throws {
        #expect(try AgentCommand.build(agent: AgentPresets.pi, model: "openai-codex/gpt-5.6-sol",
                                       reasoning: "high", prompt: "review", worktreePath: wt, launcher: launcher)
                == "pi --model openai-codex/gpt-5.6-sol --thinking high 'review'")
        #expect(AgentCommand.previewCommand(agent: AgentPresets.pi, model: "anthropic/claude-sonnet",
                                            reasoning: nil, prompt: nil)
                == "pi --model anthropic/claude-sonnet")
    }

    /// The command is typed into zsh, where an unquoted `[1m]` is a glob that matches nothing and
    /// fails the whole line with "no matches found". A word only shell-safe characters make up is
    /// left as it is, so every command above stays readable.
    @Test func testAWordZshWouldExpandIsQuoted() throws {
        #expect(try AgentCommand.build(agent: AgentPresets.claude, model: "claude-fable-5-1[1m]", reasoning: "max*", prompt: nil, worktreePath: wt, launcher: launcher)
                == "claude --model 'claude-fable-5-1[1m]' --effort 'max*'")
        #expect(AgentCommand.previewCommand(agent: AgentPresets.codex, model: "gpt-5.6", reasoning: "x y", prompt: nil)
                == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6 -c 'model_reasoning_effort=x y'")
        #expect(AgentCommand.shellWord("openai-codex/gpt-5.6-sol") == "openai-codex/gpt-5.6-sol")
        #expect(AgentCommand.shellWord("") == "''")
        // zsh's EQUALS option expands a word that starts with `=` to the path of that command.
        #expect(AgentCommand.shellWord("=ls") == "'=ls'")
        #expect(AgentCommand.shellWord("model_reasoning_effort=high") == "model_reasoning_effort=high")
    }

    @Test func testLongPromptGoesToFile() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let long = String(repeating: "x", count: 9000)
        let cmd = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: long, worktreePath: wt, launcher: launcher)
        #expect(cmd == "claude --model opus \"$(cat .shellforge/first-prompt.md)\"")
        #expect(try String(contentsOfFile: wt + "/.shellforge/first-prompt.md", encoding: .utf8) == long)
    }

    /// The command is typed into a tab whose shell may not have started its line editor yet. Until
    /// it does, the terminal is in canonical mode, where macOS keeps at most 1024 bytes of input
    /// (`MAX_CANON`) and silently drops the rest: a 1 kB prompt once lost its closing quote and
    /// left zsh waiting at `quote>`. So the limit is on the whole typed command, quoting included.
    @Test func testACommandTooLongForTheTerminalLineGoesToFile() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let fits = String(repeating: "x", count: 900)
        #expect(try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: fits, worktreePath: wt, launcher: launcher)
                == "claude --model opus '\(fits)'")
        // Short as text, but each `'` is typed as four bytes once it is quoted.
        for prompt in [String(repeating: "x", count: 1100), String(repeating: "it's ", count: 150)] {
            let cmd = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: prompt, worktreePath: wt, launcher: launcher)
            #expect(cmd == "claude --model opus \"$(cat .shellforge/first-prompt.md)\"")
            #expect(try String(contentsOfFile: wt + "/.shellforge/first-prompt.md", encoding: .utf8) == prompt)
            #expect(AgentCommand.previewCommand(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: prompt) == cmd)
        }
    }

    /// A short prompt is typed into the terminal, where a TAB completes, a lone CR accepts the
    /// line and ESC, ^C or ^U edit it — so a prompt holding any of them goes through the file.
    /// Windows line endings are only newlines, and stay inline.
    @Test func testAPromptWithControlCharactersGoesToFile() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        for prompt in ["fix\tit", "one\rtwo", "stop\u{1B}here", "x\u{03}y", "x\u{7F}y"] {
            let cmd = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: prompt, worktreePath: wt, launcher: launcher)
            #expect(cmd == "claude --model opus \"$(cat .shellforge/first-prompt.md)\"", "\(prompt.debugDescription)")
            #expect(try String(contentsOfFile: wt + "/.shellforge/first-prompt.md", encoding: .utf8) == prompt)
            #expect(AgentCommand.previewCommand(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: prompt) == cmd)
        }
        let crlf = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: "one\r\ntwo\n", worktreePath: wt, launcher: launcher)
        #expect(crlf == "claude --model opus 'one\ntwo\n'")
        #expect(AgentCommand.previewCommand(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: "one\r\ntwo") == "claude --model opus 'one\ntwo'")
    }

    /// Writing the long prompt must also add `.shellforge/` to the repository's exclude file.
    @Test func testLongPromptExcludesShellforgeDirectory() throws {
        let repo = try GitRepoFixture()
        let long = String(repeating: "x", count: 9000)
        _ = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: long, worktreePath: repo.path, launcher: repo.launcher)
        let exclude = try String(contentsOfFile: repo.path + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains(".shellforge/"))
    }

    /// The same for a linked `.worktrees/<slug>` worktree: the line lands once in the main
    /// repository's exclude file, however often the command is built.
    @Test func testLongPromptExcludesShellforgeDirectoryInLinkedWorktree() throws {
        let repo = try GitRepoFixture()
        let linkedPath = repo.path + "/.worktrees/web-1-thing"
        try repo.git("worktree", "add", "-q", "-b", "feat/web-1-thing", linkedPath, "main")
        let long = String(repeating: "x", count: 9000)
        _ = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: long, worktreePath: linkedPath, launcher: repo.launcher)
        _ = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: long, worktreePath: linkedPath, launcher: repo.launcher)
        let exclude = try String(contentsOfFile: repo.path + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.components(separatedBy: ".shellforge/").count - 1 == 1)
    }

    /// Final review item H: the New Task footer must show the exact command before any worktree
    /// exists, so the preview never touches the disk and switches to the `$(cat …)` form at the same
    /// threshold `build` uses.
    @Test func testPreviewCommandMatchesBuildWithoutTouchingDisk() {
        #expect(AgentCommand.previewCommand(agent: AgentPresets.claude, model: "opus", reasoning: "high", prompt: "/plan fix it") == "claude --model opus --effort high '/plan fix it'")
        #expect(AgentCommand.previewCommand(agent: AgentPresets.codex, model: "gpt-5.6", reasoning: nil, prompt: nil) == "codex --dangerously-bypass-approvals-and-sandbox -m gpt-5.6")

        let long = String(repeating: "x", count: 9000)
        #expect(AgentCommand.previewCommand(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: long) == "claude --model opus \"$(cat .shellforge/first-prompt.md)\"")
        #expect(!FileManager.default.fileExists(atPath: wt), "the preview must not create a worktree directory")
    }

    @Test func testComposePrompt() {
        let t = JiraTicket(key: "WEB-5447", summary: "Add graceful SIGTERM", description: "Drain in-flight tasks.", issueType: "Task", status: "In Progress", url: "https://x/browse/WEB-5447")
        #expect(AgentCommand.composePrompt(userText: "/plan first", ticket: t, appendTicket: true) ==
                       "/plan first\n\nWEB-5447: Add graceful SIGTERM\n\nDrain in-flight tasks.")
        #expect(AgentCommand.composePrompt(userText: nil, ticket: t, appendTicket: false) == nil)
        #expect(AgentCommand.composePrompt(userText: "  ", ticket: nil, appendTicket: true) == nil)
    }

    @Test func aTicketPromptOverTheLimitGoesThroughTheFile() throws {
        let worktree = try GitRepoFixture().path
        let ticket = JiraTicket(key: "WEB-1", summary: "Thing", description: String(repeating: "d", count: 1500),
                                issueType: "Task", status: nil, url: "https://x/browse/WEB-1")
        let prompt = AgentCommand.composePrompt(userText: "do it", ticket: ticket, appendTicket: true)
        let command = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: prompt,
                                             worktreePath: worktree, launcher: launcher)
        #expect(command.hasSuffix("\"$(cat .shellforge/first-prompt.md)\""))
    }

    @Test func aPromptWithEveryHazardIsTypedVerbatim() throws {
        let worktree = try GitRepoFixture().path
        let hazards = "it's \"quoted\" (not) $HOME `x`\nline two"
        let command = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: "high", prompt: hazards,
                                             worktreePath: worktree, launcher: launcher)
        #expect(command == "claude --model opus --effort high " + AgentCommand.shellQuote(hazards))
        // What zsh reads back is the prompt itself: run the quoted word through a shell.
        let echoed = try ChildProcess.run("/bin/sh", ["-c", "printf %s " + AgentCommand.shellQuote(hazards)], environment: [:], directory: nil, timeout: 5)
        #expect(echoed.stdout == hazards)
    }

    @Test func aTabOrEscapeGoesThroughTheFile() throws {
        let worktree = try GitRepoFixture().path
        let command = try AgentCommand.build(agent: AgentPresets.codex, model: "gpt-5.7", reasoning: nil, prompt: "a\tb\u{1B}c",
                                             worktreePath: worktree, launcher: launcher)
        #expect(command.hasSuffix("\"$(cat .shellforge/first-prompt.md)\""))
        #expect(try String(contentsOfFile: worktree + "/.shellforge/first-prompt.md", encoding: .utf8) == "a\tb\u{1B}c")
    }

    @Test func aLongPromptGoesThroughTheFileAndIsExcluded() throws {
        let repo = try GitRepoFixture()
        _ = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: String(repeating: "x", count: 1200),
                                   worktreePath: repo.path, launcher: repo.launcher)
        #expect(try repo.git("status", "--porcelain").isEmpty, ".shellforge/ shows as untracked")
    }

    @Test func thePreviewIsTheCommandThatRuns() throws {
        let worktree = try GitRepoFixture().path
        for prompt in [nil, "short", String(repeating: "y", count: 1200)] {
            let built = try AgentCommand.build(agent: AgentPresets.grok, model: "grok-5", reasoning: "high", prompt: prompt,
                                               worktreePath: worktree, launcher: launcher)
            #expect(AgentCommand.previewCommand(agent: AgentPresets.grok, model: "grok-5", reasoning: "high", prompt: prompt) == built)
        }
    }

    @Test func theInitialTextKeepsBackslashesAndLeadsWithASpace() {
        #expect(TabCommand.initialText(#"claude 'a \(b) c'"#) == #" claude 'a \\(b) c'"#)
    }

    /// fish reads `\'` and `\\` as escapes even inside single quotes, so a prompt holding a
    /// backslash is never typed into the shell: it goes through the file, which every shell reads alike.
    @Test func aBackslashGoesThroughTheFile() throws {
        let worktree = try GitRepoFixture().path
        let prompt = #"a\'; echo pwned #"#
        let command = try AgentCommand.build(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: prompt,
                                             worktreePath: worktree, launcher: launcher)
        #expect(command == "claude --model opus \"$(cat .shellforge/first-prompt.md)\"")
        #expect(try String(contentsOfFile: worktree + "/.shellforge/first-prompt.md", encoding: .utf8) == prompt)
        #expect(AgentCommand.previewCommand(agent: AgentPresets.claude, model: "opus", reasoning: nil, prompt: prompt) == command)
    }
}
