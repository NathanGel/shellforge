import Foundation

/// What starting an agent in a task's tab comes to: the line to type, the prompt to type into the
/// agent once it runs, and the environment to arm for `shellforge-run`. The environment holds
/// secrets, so it goes only to the helper (`armLaunch`), never into the command.
public struct AgentLaunch: Equatable, Sendable {
    public var command: String
    /// The first prompt, for an agent that takes it typed in; `TypedPrompt.paste` writes it.
    public var typedPrompt: String?
    public var agentId: String
    public var environment: [String: String]
    /// The command goes through `shellforge-run`, which takes its environment from the helper: the
    /// host arms the helper for this launch only then. A built-in's plain line takes nothing, and an
    /// arm for it would be a false failure when the helper is down and an arm no one takes.
    public var needsArming: Bool
    /// The agent's own program, as `AgentIdentity.programName` reads its command: what a typed
    /// prompt waits for in the tab's foreground (never `shellforge-run`, nor the shell). Nil when the
    /// command names none, and then a typed prompt is never typed.
    public var agentProgram: String?

    public init(command: String, typedPrompt: String?, agentId: String, environment: [String: String], needsArming: Bool = false,
                agentProgram: String? = nil) {
        self.command = command
        self.typedPrompt = typedPrompt
        self.agentId = agentId
        self.environment = environment
        self.needsArming = needsArming
        self.agentProgram = agentProgram
    }

    public struct RunnerMissing: Error, Equatable, LocalizedError {
        public init() {}
        public var errorDescription: String? { "Shellforge couldn’t find shellforge-run in its app bundle." }
    }

    /// Whether the command goes through `shellforge-run`: every agent that isn't built in, so its id
    /// is always set, and a built-in too once it has an environment of its own. A hand-written agent
    /// file whose id the runner can't take (`AgentRegistry.isValidId`) and that has no environment
    /// starts unwrapped, as it did before the runner; with an environment, `runPrefix` refuses it.
    static func isWrapped(_ agent: AgentDefinition, hasEnvironment: Bool) -> Bool {
        hasEnvironment || (!AgentPresets.isBuiltIn(agent.id) && AgentRegistry.isValidId(agent.id))
    }

    public static func make(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?, worktreePath: String,
                            launcher: CommandLauncher, secrets: any SecretStore, runner: URL?) throws -> AgentLaunch {
        let environment = try AgentSecrets.environment(for: agent, store: secrets)
        let wrapped = isWrapped(agent, hasEnvironment: !environment.isEmpty)
        let prefix = wrapped ? try runPrefix(runner: runner, id: agent.id) : nil
        let plan = try AgentCommand.prepare(agent: agent, model: model, reasoning: reasoning, prompt: prompt, prefix: prefix,
                                            worktreePath: worktreePath, launcher: launcher)
        let typed = AgentCommand.normalizedPrompt(prompt)
        return AgentLaunch(command: plan.line, typedPrompt: agent.prompt == .typed ? typed : nil, agentId: agent.id,
                           environment: wrapped ? environment : [:], needsArming: wrapped,
                           agentProgram: AgentIdentity.programName(agent.command))
    }

    /// The command `make` would build, for the New Task footer: nothing is written, no secret is
    /// read, and `hasEnvironment` says whether the agent has plain variables or secrets.
    public static func previewCommand(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?,
                                      runner: URL?) throws -> String {
        let hasEnvironment = !agent.environment.isEmpty || !agent.secrets.isEmpty
        let prefix = isWrapped(agent, hasEnvironment: hasEnvironment) ? try runPrefix(runner: runner, id: agent.id) : nil
        return try AgentCommand.plan(agent: agent, model: model, reasoning: reasoning, prompt: prompt, prefix: prefix).line
    }

    /// `'<runner>' <id> -- `. Words that follow are quoted whole by the caller. The runner's path is
    /// a word too, and the id is checked against what `AgentRegistry` allows, since it is typed bare.
    private static func runPrefix(runner: URL?, id: String) throws -> String {
        guard AgentRegistry.isValidId(id) else { throw AgentRegistry.Refusal.invalidId(id) }
        guard let runner else { throw RunnerMissing() }
        for scalar in runner.path.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F || scalar == "\\" {
            throw AgentCommand.UnsafeWord(field: "path of shellforge-run", reason: scalar == "\\" ? .backslash : .control)
        }
        return "\(AgentCommand.shellQuote(runner.path)) \(id) -- "
    }
}
