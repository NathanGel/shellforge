import Foundation

/// What Shellforge may have inherited from whoever started it and must not hand on. Started with
/// `open` from inside an agent's session — Claude Code's — the app gets that session's markers, and
/// iTerm2 gives its own environment to every tab: a `claude` started there then takes itself for
/// that session's child and turns transcript saving off. A person's own settings for those tools
/// (`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CONFIG_DIR`, `CODEX_HOME`) are not markers and stay.
public enum InheritedEnvironment {
    /// Claude Code's session markers, and the generic agent flag.
    static let markers: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_SSE_PORT", "CLAUDE_PID", "CLAUDE_EFFORT", "AI_AGENT",
    ]

    /// The markers `environment` holds.
    public static func agentMarkers(in environment: [String: String]) -> [String] {
        environment.keys.filter(markers.contains)
    }
}
