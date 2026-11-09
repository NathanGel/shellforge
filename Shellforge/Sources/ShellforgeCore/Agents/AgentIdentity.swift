import Foundation

/// Which custom agent a tab runs. A task's tab is its own agent's, while that agent's program is in
/// its foreground; only a tab with no task agent is matched against every agent's program name.
public enum AgentIdentity {
    public static let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "login"]
    public static let interpreters: Set<String> = ["node", "nodejs", "bun", "deno", "python", "python3", "ruby"]

    private static func words(_ commandLine: String) -> [String] {
        ShellWords.split(commandLine) ?? commandLine.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func basename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
    }

    /// Case doesn't matter: a macOS framework Python (Homebrew's, pipx's) runs as `…/Python`.
    private static func isInterpreter(_ name: String) -> Bool {
        let name = name.lowercased()
        return interpreters.contains(name) || name.range(of: #"^python3?\.\d+$"#, options: .regularExpression) != nil
    }

    /// Nil and empty count as a shell, and a leading `-` (a login shell) is ignored.
    public static func isShell(_ commandLine: String?) -> Bool {
        guard let commandLine, let first = words(commandLine).first else { return true }
        var name = basename(first)
        if name.hasPrefix("-") { name.removeFirst() }
        return shellNames.contains(name)
    }

    /// The basename of argv[0], or of the script after an interpreter.
    public static func programName(_ commandLine: String) -> String? {
        let w = words(commandLine)
        guard let first = w.first else { return nil }
        let name = basename(first)
        guard isInterpreter(name) else { return name.isEmpty ? nil : name }
        guard let script = w.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return name }
        let s = basename(script)
        return s.isEmpty ? nil : s
    }

    /// What is in the foreground of a tab a typed prompt waits on.
    public enum Foreground: Equatable, Sendable {
        case shell
        /// `shellforge-run`: its zsh script, or `run_agent.py` under the helper's Python, taking the
        /// launch's settings. It is never the agent, however long it waits.
        case runner
        /// The launch's own agent: its command's program, by `programName`.
        case agent
        /// Any other program.
        case other
    }

    /// The runner's two forms, by the name of the script either runs.
    public static let runnerNames: Set<String> = ["shellforge-run", "run_agent.py"]

    /// `shellforge-run` in the foreground: a word before its `--` is one of `runnerNames`, so the
    /// interpreter running it (a shell, or a Python by any name) doesn't matter.
    static func isRunner(_ commandLine: String) -> Bool {
        words(commandLine).prefix { $0 != "--" }.contains { runnerNames.contains(basename($0)) }
    }

    /// `agentProgram` is the launch's `AgentLaunch.agentProgram`.
    public static func foreground(_ commandLine: String?, agentProgram: String) -> Foreground {
        if let commandLine, isRunner(commandLine) { return .runner }
        if isShell(commandLine) { return .shell }
        guard let commandLine, let program = programName(commandLine) else { return .other }
        return program == agentProgram ? .agent : .other
    }

    /// A task's own agent is the tab's only while its program (or `shellforge-run`, starting it) is
    /// in the foreground: an editor, a build or a pager in that tab is not the agent, and gets no
    /// guessed status. A task agent whose definition is gone is never recognised.
    public static func customAgent(taskAgent: String?, commandLine: String?, agents: [AgentDefinition]) -> String? {
        if let taskAgent {
            guard !AgentPresets.isBuiltIn(taskAgent), let agent = agents.first(where: { $0.id == taskAgent }),
                  let program = programName(agent.command) else { return nil }
            switch foreground(commandLine, agentProgram: program) {
            case .agent, .runner: return taskAgent
            case .shell, .other: return nil
            }
        }
        if isShell(commandLine) { return nil }
        guard let commandLine, let program = programName(commandLine), !isInterpreter(program) else { return nil }
        let commandName = { (a: AgentDefinition) in programName(a.command) }
        if AgentPresets.all.contains(where: { commandName($0) == program }) { return nil }
        let matches = agents.filter { !AgentPresets.isBuiltIn($0.id) && commandName($0) == program }
        return matches.count == 1 ? matches[0].id : nil
    }
}
