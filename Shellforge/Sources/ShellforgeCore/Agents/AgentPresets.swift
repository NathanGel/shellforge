/// The agents Shellforge knows out of the box, launched exactly as AiTerm launches them. Each has a
/// built-in status adapter; a user can override one by saving an agent with the same id.
public enum AgentPresets {
    public static let all = [claude, codex, grok, pi]

    public static let claude = AgentDefinition(
        id: "claude", name: "Claude Code", command: "claude",
        arguments: [["--model", "{model}"], ["--effort", "{reasoning}"]],
        reasoningLevels: ["low", "medium", "high"], defaultReasoning: "high", status: .preset("claude"))

    /// Codex runs without its approval prompts or sandbox, as in AiTerm; New Task shows the flag
    /// in its command preview before anything runs.
    public static let codex = AgentDefinition(
        id: "codex", name: "Codex", command: "codex",
        arguments: [["--dangerously-bypass-approvals-and-sandbox"], ["-m", "{model}"], ["-c", "model_reasoning_effort={reasoning}"]],
        reasoningLevels: ["minimal", "low", "medium", "high", "xhigh"], defaultReasoning: "medium", status: .preset("codex"))

    public static let grok = AgentDefinition(
        id: "grok", name: "Grok Build", command: "grok",
        arguments: [["-m", "{model}"], ["--reasoning-effort", "{reasoning}"]],
        reasoningLevels: ["low", "medium", "high", "xhigh"], defaultReasoning: "high", status: .preset("grok"))

    public static let pi = AgentDefinition(
        id: "pi", name: "PI", command: "pi",
        arguments: [["--model", "{model}"], ["--thinking", "{reasoning}"]],
        reasoningLevels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"], defaultReasoning: "medium",
        status: .preset("pi"))
}
