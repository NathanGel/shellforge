import Foundation

/// One typed-in prompt on its way into a task's tab: `TypingReadiness`, fed from the tab's terminal
/// by the host every quarter second or so, and the paste it gives back to write, once. The host
/// owns the tab and the timer; this owns the decision, so it can be tested without either. It types
/// only while the launch's own agent is in the foreground, never while `shellforge-run` is still
/// taking the launch's settings, and gives up when the shell comes back first.
public struct TypedPromptDriver: Sendable {
    public enum Step: Equatable, Sendable {
        case wait
        /// Write these bytes to the tab. Given exactly once.
        case type(String)
        /// Nothing will be typed. `agentExited`: the agent ran and ended before the prompt went, which
        /// the sidebar says (`SidebarModel.typedPromptAbandoned`). An agent that never ran says nothing:
        /// `shellforge-run` has said why in the tab.
        case abandon(agentExited: Bool)
        /// Typed or abandoned already: stop feeding it.
        case finished
    }

    private var readiness: TypingReadiness
    private let paste: String
    private let agentProgram: String
    private var sawAgent = false
    private var over = false

    /// Nil when the launch has no prompt to type, or no program of its own to wait for.
    public init?(launch: AgentLaunch, armedAt: Date) {
        guard let prompt = launch.typedPrompt, !prompt.isEmpty, let program = launch.agentProgram else { return nil }
        paste = TypedPrompt.paste(prompt)
        agentProgram = program
        readiness = TypingReadiness(armedAt: armedAt)
    }

    /// `commandLine`: the tab's foreground command line (its `commandLine` variable). Only the
    /// launch's own agent counts as running (`AgentIdentity.foreground`): never `shellforge-run`,
    /// which may wait well past the ceiling for its settings, and never a shell.
    /// `outputBytes`: the tab's `TerminalSignals.outputBytes`.
    public mutating func observe(commandLine: String?, outputBytes: Int, now: Date) -> Step {
        guard !over else { return .finished }
        let foreground = AgentIdentity.foreground(commandLine, agentProgram: agentProgram)
        if foreground == .agent { sawAgent = true }
        switch readiness.observe(foreground, outputBytes: outputBytes, now: now) {
        case .wait: return .wait
        case .type:
            over = true
            return .type(paste)
        case .abandon:
            over = true
            return .abandon(agentExited: sawAgent && foreground == .shell)
        }
    }

    /// Right before `type`'s bytes are written: the tab's foreground read again, fresh. The poll
    /// behind `observe`'s `commandLine` can trail the tab by half a second or more, so the agent may
    /// have ended since; the bytes go only if its own program is still in the foreground. `.type`
    /// with the same paste when it is, else `.abandon`, saying the agent exited when a shell is back.
    public func confirm(commandLine: String?) -> Step {
        switch AgentIdentity.foreground(commandLine, agentProgram: agentProgram) {
        case .agent: return .type(paste)
        case .shell: return .abandon(agentExited: true)
        case .runner, .other: return .abandon(agentExited: false)
        }
    }
}
