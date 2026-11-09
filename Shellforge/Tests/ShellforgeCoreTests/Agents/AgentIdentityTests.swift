import Testing
@testable import ShellforgeCore

@Suite struct AgentIdentityTests {
    private func agent(_ id: String, _ command: String) -> AgentDefinition { AgentDefinition(id: id, name: id, command: command) }
    private let agents = [AgentDefinition(id: "gemini", name: "Gemini", command: "gemini"),
                          AgentDefinition(id: "aider", name: "Aider", command: "aider")]

    @Test func taskAgentWinsForItsOwnProgram() {
        #expect(AgentIdentity.customAgent(taskAgent: "gemini", commandLine: "node /opt/homebrew/bin/gemini", agents: agents) == "gemini")
        #expect(AgentIdentity.customAgent(taskAgent: "gemini", commandLine: "/opt/homebrew/bin/gemini --yolo", agents: agents) == "gemini")
    }

    /// I1: any other program in a custom agent's task tab is not the agent, so it gets no guessed dot.
    @Test func anotherProgramInACustomTaskTabIsNothing() {
        for line in ["vim notes.md", "npm test", "less README.md", "aider", "python3 /x/script.py"] {
            #expect(AgentIdentity.customAgent(taskAgent: "gemini", commandLine: line, agents: agents) == nil, "\(line)")
        }
        // A task agent whose definition is gone can't be recognised.
        #expect(AgentIdentity.customAgent(taskAgent: "gone", commandLine: "gone", agents: agents) == nil)
    }

    /// While `shellforge-run` starts the task's agent, the tab is already that agent's.
    @Test func theRunnerLaunchingTheTaskAgentIsIt() {
        let runner = "/usr/local/bin/python3 -I /App/daemon/shellforged/run_agent.py gemini -- gemini"
        #expect(AgentIdentity.customAgent(taskAgent: "gemini", commandLine: runner, agents: agents) == "gemini")
        #expect(AgentIdentity.customAgent(taskAgent: "gemini", commandLine: "/bin/zsh -f /App/hooks/shellforge-run gemini -- gemini",
                                          agents: agents) == "gemini")
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: runner, agents: agents) == nil)
    }

    @Test func builtInTaskSendsNothing() {
        #expect(AgentIdentity.customAgent(taskAgent: "claude", commandLine: "claude", agents: agents) == nil)
        #expect(AgentIdentity.customAgent(taskAgent: "claude", commandLine: "aider", agents: agents) == nil)
    }

    @Test func shellIsNothing() {
        for line in ["-zsh", "/bin/zsh -l", nil, ""] {
            #expect(AgentIdentity.isShell(line))
            #expect(AgentIdentity.customAgent(taskAgent: "gemini", commandLine: line, agents: agents) == nil)
            #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: line, agents: agents) == nil)
        }
        #expect(!AgentIdentity.isShell("aider"))
    }

    @Test func nameMatchWithoutATask() {
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "node /opt/homebrew/bin/gemini", agents: agents) == "gemini")
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "python3 /x/aider --yes", agents: agents) == "aider")
        #expect(AgentIdentity.programName("node /opt/homebrew/bin/gemini") == "gemini")
        #expect(AgentIdentity.programName("/usr/local/bin/aider --yes") == "aider")
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "vim", agents: agents) == nil)
    }

    /// R1: a macOS framework Python runs as `…/Python`, as aider does when installed with Homebrew or pipx.
    @Test func aFrameworkPythonIsAnInterpreter() {
        let line = "/opt/homebrew/Cellar/python@3.12/3.12.7/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python /opt/homebrew/bin/aider --yes"
        #expect(AgentIdentity.programName(line) == "aider")
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: line, agents: agents) == "aider")
        #expect(AgentIdentity.programName("/usr/local/bin/Python3.12 /x/aider") == "aider")
    }

    @Test func builtInsWinACollision() {
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "claude", agents: [agent("mine", "claude")]) == nil)
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "node /x/codex", agents: [agent("mine", "codex")]) == nil)
    }

    @Test func twoCustomAgentsWithOneCommandAreNothing() {
        let two = [agent("a", "tool"), agent("b", "/usr/bin/tool")]
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "tool", agents: two) == nil)
        #expect(AgentIdentity.customAgent(taskAgent: "a", commandLine: "tool", agents: two) == "a")
    }

    @Test func anInterpreterAgentMatchesItsScriptNotABareInterpreter() {
        let node = [agent("cli", "node cli.js"), agent("py", "python3 -m aider")]
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "node /x/cli.js", agents: node) == "cli")
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "python3 /x/aider", agents: node) == "py")
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "node", agents: [agent("n", "node")]) == nil)
        #expect(AgentIdentity.customAgent(taskAgent: nil, commandLine: "python3", agents: [agent("p", "python3")]) == nil)
    }

    /// What a typed prompt waits for: only the launch's own agent counts as the agent. The runner,
    /// in either of its forms, is never the agent, and neither is a shell or any other program.
    @Test func theForegroundOfATypedPromptsTab() {
        let runnerScript = "/bin/zsh -f /Applications/Shellforge.app/Contents/Resources/hooks/shellforge-run aider -- aider"
        let runnerPython = "/usr/local/bin/python3.12 -I /Applications/Shellforge.app/Contents/Resources/hooks/../daemon/shellforged/run_agent.py aider -- aider"
        #expect(AgentIdentity.foreground(runnerScript, agentProgram: "aider") == .runner)
        #expect(AgentIdentity.foreground(runnerPython, agentProgram: "aider") == .runner)
        #expect(AgentIdentity.foreground("/opt/venv/bin/Python -I /x/run_agent.py aider -- aider", agentProgram: "aider") == .runner)
        #expect(AgentIdentity.foreground("-zsh", agentProgram: "aider") == .shell)
        #expect(AgentIdentity.foreground(nil, agentProgram: "aider") == .shell)
        #expect(AgentIdentity.foreground("/usr/local/bin/aider --model m", agentProgram: "aider") == .agent)
        #expect(AgentIdentity.foreground("node /opt/homebrew/bin/gemini", agentProgram: "gemini") == .agent)
        #expect(AgentIdentity.foreground("vim notes.md", agentProgram: "aider") == .other)
        #expect(AgentIdentity.foreground("python3 /x/other.py", agentProgram: "aider") == .other)
    }
}
