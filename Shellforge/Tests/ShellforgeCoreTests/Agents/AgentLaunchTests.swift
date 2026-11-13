import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct AgentLaunchTests {
    let wt = TestScratch.root.appendingPathComponent("wt-\(UUID().uuidString)").path
    let launcher = CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin"], source: .loginShell("/bin/sh")) }
    let runner = URL(fileURLWithPath: "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-run")

    private func gemini(_ arguments: [[String]] = [["-i", "{prompt}"]], command: String = "gemini", secrets: [String: String] = [:],
                        environment: [String: String] = [:], prompt: AgentDefinition.PromptDelivery = .argument) -> AgentDefinition {
        AgentDefinition(id: "gemini", name: "Gemini CLI", command: command, arguments: arguments, prompt: prompt,
                        environment: environment, secrets: secrets)
    }

    private func make(_ agent: AgentDefinition, prompt: String? = "fix it", store: MemorySecretStore = MemorySecretStore(),
                      runner: URL? = nil) throws -> AgentLaunch {
        try AgentLaunch.make(agent: agent, model: "m", reasoning: nil, prompt: prompt, worktreePath: wt, launcher: launcher,
                             secrets: store, runner: runner ?? self.runner)
    }

    /// Only a launch through `shellforge-run` is armed: a built-in's plain line takes nothing from
    /// the helper, and arming it would leave an arm no one takes.
    @Test func onlyAWrappedLaunchNeedsArming() throws {
        #expect(try make(AgentPresets.claude).needsArming == false)
        #expect(try make(gemini()).needsArming)
        var claude = AgentPresets.claude
        claude.environment = ["MODE": "fast"]
        #expect(try make(claude).needsArming, "a built-in with an environment goes through the runner")
    }

    @Test func plainAgentIsNotWrapped() throws {
        let launch = try make(AgentPresets.claude)
        #expect(launch.command == "claude --model m 'fix it'")
        #expect(launch.agentId == "claude" && launch.environment.isEmpty)
        // A built-in needs no runner at all.
        #expect(try AgentLaunch.make(agent: AgentPresets.claude, model: "m", reasoning: nil, prompt: nil, worktreePath: wt,
                                     launcher: launcher, secrets: MemorySecretStore(), runner: nil).command == "claude --model m")
    }

    @Test func everyAgentThatIsNotBuiltInIsWrappedEvenWithNoEnvironment() throws {
        let launch = try make(gemini())
        #expect(launch.command == "'\(runner.path)' gemini -- 'gemini' '-i' 'fix it'")
        #expect(launch.agentProgram == "gemini", "a typed prompt waits for the agent, not the runner")
        #expect(launch.environment.isEmpty)
    }

    @Test func agentWithEnvironmentIsWrapped() throws {
        let store = MemorySecretStore()
        store.set("agent.gemini.GEMINI_API_KEY", "placeholder-value")
        let launch = try make(gemini(secrets: ["GEMINI_API_KEY": "agent.gemini.GEMINI_API_KEY"], environment: ["MODE": "fast"]), store: store)
        #expect(launch.command.hasPrefix("'\(runner.path)' gemini -- 'gemini'"))
        #expect(launch.environment == ["MODE": "fast", "GEMINI_API_KEY": "placeholder-value"])
    }

    @Test func aBuiltInOverrideWithEnvironmentIsWrapped() throws {
        var claude = AgentPresets.claude
        claude.environment = ["MODE": "fast"]
        let launch = try make(claude)
        #expect(launch.command == "'\(runner.path)' claude -- 'claude' '--model' 'm' 'fix it'")
        #expect(launch.environment == ["MODE": "fast"])
    }

    @Test func bundlePathWithSpacesIsQuoted() throws {
        let spaced = URL(fileURLWithPath: "/Applications/My Apps/Shellforge.app/Contents/Resources/hooks/shellforge-run")
        let launch = try make(gemini(), runner: spaced)
        #expect(launch.command.hasPrefix("'/Applications/My Apps/Shellforge.app/Contents/Resources/hooks/shellforge-run' gemini -- "))
        #expect(ShellWords.split(launch.command)?.first == spaced.path)
    }

    @Test func noValueInTheCommand() throws {
        let store = MemorySecretStore()
        store.set("agent.gemini.GEMINI_API_KEY", "placeholder-value")
        let launch = try make(gemini(secrets: ["GEMINI_API_KEY": "agent.gemini.GEMINI_API_KEY"], environment: ["MODE": "fast-plain"]), store: store)
        #expect(!launch.command.contains("placeholder-value") && !launch.command.contains("fast-plain"))
    }

    @Test func runnerMissingThrows() {
        #expect(throws: AgentLaunch.RunnerMissing()) { try AgentLaunch.make(agent: gemini(), model: "m", reasoning: nil, prompt: nil,
            worktreePath: wt, launcher: launcher, secrets: MemorySecretStore(), runner: nil) }
        #expect(AgentLaunch.RunnerMissing().localizedDescription == "Shellforge couldn’t find shellforge-run in its app bundle.")
        #expect(throws: AgentLaunch.RunnerMissing()) { try AgentLaunch.previewCommand(agent: gemini(), model: "m", reasoning: nil, prompt: nil, runner: nil) }
    }

    @Test func typedPromptCarried() throws {
        let launch = try make(gemini([["--yolo"]], prompt: .typed), prompt: "hello\r\nthere")
        #expect(launch.typedPrompt == "hello\nthere")
        #expect(!launch.command.contains("hello"))
        #expect(try make(gemini([["{prompt}"]]), prompt: "hello").typedPrompt == nil)
        #expect(try make(gemini([["--yolo"]], prompt: .noPrompt), prompt: "hello").typedPrompt == nil)
    }

    @Test func aMissingSecretStopsTheLaunch() {
        #expect(throws: AgentSecrets.Missing.self) { try make(gemini(secrets: ["GEMINI_API_KEY": "ref"])) }
    }

    private static let invalidIds = ["a b", "x;rm -rf", "", "a'b", String(repeating: "a", count: 65), "$(x)", "my.agent"]

    /// An id `shellforge-run` can't take is never typed: an agent that needs wrapping (it has an
    /// environment or secrets) is refused with the registry's sentence.
    @Test func invalidIdIsNeverTyped() {
        let store = MemorySecretStore()
        for id in Self.invalidIds {
            store.set("agent.shared.GEMINI_API_KEY", "placeholder-value")
            for var bad in [gemini(environment: ["MODE": "fast"]), gemini(secrets: ["GEMINI_API_KEY": "agent.shared.GEMINI_API_KEY"])] {
                bad.id = id
                #expect(throws: AgentRegistry.Refusal.invalidId(id)) { try make(bad, store: store) }
                #expect(throws: AgentRegistry.Refusal.invalidId(id)) { try AgentLaunch.previewCommand(agent: bad, model: "m", reasoning: nil, prompt: nil, runner: runner) }
            }
        }
    }

    /// I3: a hand-written agent file whose id `shellforge-run` can't take, with no environment or
    /// secrets, starts as it did before 0.9.0: its plain line, unwrapped, with nothing armed.
    @Test func anInvalidIdWithNoEnvironmentStartsUnwrapped() throws {
        for id in Self.invalidIds {
            var old = gemini()
            old.id = id
            let launch = try make(old)
            #expect(launch.command == "gemini -i 'fix it'", "\(id)")
            #expect(!launch.needsArming && launch.environment.isEmpty)
            #expect(try AgentLaunch.previewCommand(agent: old, model: "m", reasoning: nil, prompt: "fix it", runner: runner) == launch.command)
            // No runner is needed for it either.
            #expect(try AgentLaunch.make(agent: old, model: "m", reasoning: nil, prompt: "fix it", worktreePath: wt, launcher: launcher,
                                         secrets: MemorySecretStore(), runner: nil).command == launch.command)
        }
    }

    /// What a shell reads back from the typed line is exactly the agent's words: nothing the file
    /// holds is expanded, split or run.
    @Test func hostileCommandStaysWords() throws {
        let hostile = "my agent's $HOME `id`; echo pwned"
        let agent = gemini([["--flag", "a b", "it's", "$(id)", "x;y", "`z`", "--p={prompt}"]], command: hostile)
        let launch = try make(agent, prompt: "it's \"$HOME\" `x`; y")
        let words = try #require(ShellWords.split(launch.command))
        #expect(words == [runner.path, "gemini", "--", hostile, "--flag", "a b", "it's", "$(id)", "x;y", "`z`", "--p=it's \"$HOME\" `x`; y"])
        // And a real shell agrees: printf shows one line per word, none of them run or expanded.
        let argv = String(launch.command[try #require(launch.command.range(of: " -- ")).upperBound...])
        let shown = try ChildProcess.run("/bin/sh", ["-c", "printf '%s\\n' " + argv], environment: [:], directory: nil, timeout: 5)
        #expect(shown.stdout == words.dropFirst(3).joined(separator: "\n") + "\n")
    }

    @Test func promptFileIsExpandedByTheShellInAWrappedLine() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let long = String(repeating: "x", count: 2000)
        let launch = try make(gemini([["--p={prompt}"]]), prompt: long)
        #expect(launch.command == "'\(runner.path)' gemini -- 'gemini' '--p='\"$(cat .shellforge/first-prompt.md; rm -f .shellforge/first-prompt.md)\"")
    }

    @Test func previewIsTheCommandThatRuns() throws {
        for prompt in [nil, "short", String(repeating: "z", count: 2000)] {
            let agent = gemini([["-i", "{prompt}"], ["--yolo"]])
            #expect(try AgentLaunch.previewCommand(agent: agent, model: "m", reasoning: nil, prompt: prompt, runner: runner)
                    == make(agent, prompt: prompt).command)
        }
    }

    @Test func aDollarOrQuoteInAWordIsOnlyText() throws {
        // `make` is the only way to a wrapped line, so no later step can reread these words.
        let launch = try make(gemini([["$(cat .shellforge/first-prompt.md)", "$HOME", "\"x\""]]), prompt: nil)
        #expect(ShellWords.split(launch.command)?.suffix(4) == ["gemini", "$(cat .shellforge/first-prompt.md)", "$HOME", "\"x\""])
    }

    @Test func controlCharactersInAWordAreRefused() {
        for bad in ["a\u{15}b", "a\rb", "a\tb", "a\nb", "a\u{7F}b", "\u{1B}"] {
            #expect(throws: AgentCommand.UnsafeWord(field: "arguments", reason: .control)) { try make(gemini([["--x", bad]])) }
            #expect(throws: AgentCommand.UnsafeWord(field: "command", reason: .control)) { try make(gemini(command: bad)) }
            #expect(throws: AgentCommand.UnsafeWord(field: "model", reason: .control)) {
                try AgentLaunch.make(agent: gemini(), model: bad, reasoning: nil, prompt: nil, worktreePath: wt, launcher: launcher,
                                     secrets: MemorySecretStore(), runner: runner)
            }
            #expect(throws: AgentCommand.UnsafeWord(field: "reasoning level", reason: .control)) {
                try AgentLaunch.make(agent: gemini(), model: "m", reasoning: bad, prompt: nil, worktreePath: wt, launcher: launcher,
                                     secrets: MemorySecretStore(), runner: runner)
            }
            // Built-ins too: the line is typed either way.
            #expect(throws: AgentCommand.UnsafeWord(field: "model", reason: .control)) {
                try AgentLaunch.make(agent: AgentPresets.claude, model: bad, reasoning: nil, prompt: nil, worktreePath: wt,
                                     launcher: launcher, secrets: MemorySecretStore(), runner: runner)
            }
        }
        #expect(AgentCommand.UnsafeWord(field: "model", reason: .control).localizedDescription.hasPrefix("The model holds a control character"))
    }

    @Test func aBackslashInAWrappedWordIsRefused() {
        #expect(throws: AgentCommand.UnsafeWord(field: "arguments", reason: .backslash)) { try make(gemini([["--x", "a\\"]])) }
        #expect(throws: AgentCommand.UnsafeWord(field: "command", reason: .backslash)) { try make(gemini(command: "C:\\gemini")) }
        #expect(throws: AgentCommand.UnsafeWord(field: "path of shellforge-run", reason: .backslash)) {
            try make(gemini(), runner: URL(fileURLWithPath: "/Apps/a\\b/shellforge-run"))
        }
    }

    /// The runner, the id and the quote bytes of every word make the wrapped line longer than the
    /// plain one. The limit is on what is typed, so a prompt that fits the plain line goes through the file.
    @Test func theWrappedLineIsWhatTheLimitMeasures() throws {
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        let prompt = String(repeating: "p", count: 950)
        let agent = gemini([["-i", "{prompt}"]])
        let launch = try make(agent, prompt: prompt)
        #expect(launch.command.hasSuffix("'-i' \"$(cat .shellforge/first-prompt.md; rm -f .shellforge/first-prompt.md)\""))
        #expect(try String(contentsOfFile: wt + "/.shellforge/first-prompt.md", encoding: .utf8) == prompt)
        #expect(launch.command.utf8.count <= AgentCommand.inlineLimit)
        // The same prompt for a built-in stays inline.
        #expect(try make(AgentPresets.claude, prompt: prompt).command.contains(prompt))
        #expect(try AgentLaunch.previewCommand(agent: agent, model: "m", reasoning: nil, prompt: prompt, runner: runner) == launch.command)
    }

    @Test func aValueHoldingThePromptPlaceholderIsOnlyText() throws {
        let agent = gemini([["--model", "{model}"], ["-i", "{prompt}"]])
        let launch = try AgentLaunch.make(agent: agent, model: "{prompt}", reasoning: nil, prompt: "the plan", worktreePath: wt,
                                          launcher: launcher, secrets: MemorySecretStore(), runner: runner)
        #expect(ShellWords.split(launch.command)?.suffix(4) == ["--model", "{prompt}", "-i", "the plan"])
    }
}
