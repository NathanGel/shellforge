import Foundation
import Testing
@testable import ShellforgeCore

/// Shellforge started from inside an agent's session inherits its markers; no tab should.
@Suite struct InheritedEnvironmentTests {
    @Test func agentSessionMarkersAreNamed() {
        let env = ["CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "x",
                   "CLAUDE_CODE_MESSAGING_SOCKET": "/s", "CLAUDE_CODE_MESSAGING_TOKEN": "t", "CLAUDE_CODE_ENTRYPOINT": "cli",
                   "CLAUDE_CODE_SESSION_ATTENDED": "1", "CLAUDE_CODE_EXECPATH": "/c", "CLAUDE_CODE_SSE_PORT": "1",
                   "CLAUDE_PID": "1", "CLAUDE_EFFORT": "high", "AI_AGENT": "claude", "PATH": "/usr/bin"]
        #expect(InheritedEnvironment.agentMarkers(in: env).sorted() == env.keys.filter { $0 != "PATH" }.sorted())
    }

    @Test func aPersonsOwnSettingsAreKept() {
        let env = ["CLAUDE_CODE_USE_BEDROCK": "1", "CLAUDE_CONFIG_DIR": "/c", "CODEX_HOME": "/x", "HOME": "/h", "TERM_PROGRAM": "iTerm.app"]
        #expect(InheritedEnvironment.agentMarkers(in: env).isEmpty)
    }
}
