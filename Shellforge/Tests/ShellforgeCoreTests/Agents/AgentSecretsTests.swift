import Testing
@testable import ShellforgeCore

@Suite struct AgentSecretsTests {
    private let agent = AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini",
                                        environment: ["MODE": "fast"], secrets: ["GEMINI_API_KEY": "agent.gemini.GEMINI_API_KEY"])

    @Test func keyIsPerAgent() {
        #expect(AgentSecrets.key(agent: "gemini", variable: "GEMINI_API_KEY") == "agent.gemini.GEMINI_API_KEY")
    }

    @Test func environmentMergesSecrets() throws {
        let store = MemorySecretStore()
        store.set("agent.gemini.GEMINI_API_KEY", "placeholder-value")
        #expect(try AgentSecrets.environment(for: agent, store: store) == ["MODE": "fast", "GEMINI_API_KEY": "placeholder-value"])
    }

    @Test func missingSecretThrowsItsSentence() {
        let error = #expect(throws: AgentSecrets.Missing.self) { try AgentSecrets.environment(for: agent, store: MemorySecretStore()) }
        #expect(error?.localizedDescription == "Gemini CLI’s secret GEMINI_API_KEY isn’t in the Keychain. Set it again in Settings › Agents.")
    }

    @Test func aSecretOfAnotherAgentDoesNotCount() {
        let store = MemorySecretStore()
        store.set("agent.other.GEMINI_API_KEY", "placeholder-value")
        #expect(throws: AgentSecrets.Missing.self) { try AgentSecrets.environment(for: agent, store: store) }
    }

    @Test func removeAllKeepsOtherAgentsAndJira() {
        let store = MemorySecretStore()
        store.set("agent.gemini.GEMINI_API_KEY", "a")
        store.set("agent.other.X", "b")
        store.set("agent.gemini-2.GEMINI_API_KEY", "c")
        store.set("jira.token", "d")
        AgentSecrets.removeAll(for: agent, store: store)
        #expect(store.get("agent.gemini.GEMINI_API_KEY") == nil)
        #expect(store.get("agent.other.X") == "b" && store.get("agent.gemini-2.GEMINI_API_KEY") == "c" && store.get("jira.token") == "d")
    }

    /// I3: a hand-written file names its own Keychain item for a secret; that item is the one read.
    @Test func aFileNamesItsOwnItem() throws {
        let own = AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini", secrets: ["GEMINI_API_KEY": "agent.shared.GEMINI_API_KEY"])
        let store = MemorySecretStore()
        store.set("agent.shared.GEMINI_API_KEY", "placeholder-value")
        store.set("agent.gemini.GEMINI_API_KEY", "not-this-one")
        #expect(try AgentSecrets.environment(for: own, store: store) == ["GEMINI_API_KEY": "placeholder-value"])
        // Its item missing still refuses, pointing to Settings › Agents.
        let missing = #expect(throws: AgentSecrets.Missing.self) {
            try AgentSecrets.environment(for: own, store: MemorySecretStore())
        }
        #expect(missing?.localizedDescription.hasSuffix("Settings › Agents.") == true)
    }

    /// A file that names no item reads the one the form writes, `agent.<id>.<VARIABLE>`.
    @Test func anUnnamedItemIsTheFormsOne() throws {
        let unnamed = AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini", secrets: ["GEMINI_API_KEY": ""])
        let store = MemorySecretStore()
        store.set("agent.gemini.GEMINI_API_KEY", "placeholder-value")
        #expect(try AgentSecrets.environment(for: unnamed, store: store) == ["GEMINI_API_KEY": "placeholder-value"])
    }

    /// R2: a name outside `agent.` reads the form's entry instead, never another feature's.
    @Test func aFileCantNameAnotherFeaturesItem() throws {
        let store = MemorySecretStore()
        for name in ["jira.token", "gitlab.token", "github.token", "backpack.password", "agent.", "Agent.x.Y"] {
            store.set(name, "not-for-agents")
            let agent = AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini", secrets: ["GEMINI_API_KEY": name])
            #expect(AgentSecrets.item(of: agent, variable: "GEMINI_API_KEY") == "agent.gemini.GEMINI_API_KEY")
            #expect(throws: AgentSecrets.Missing.self) { try AgentSecrets.environment(for: agent, store: store) }
        }
        store.set("agent.gemini.GEMINI_API_KEY", "placeholder-value")
        let agent = AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini", secrets: ["GEMINI_API_KEY": "jira.token"])
        #expect(try AgentSecrets.environment(for: agent, store: store) == ["GEMINI_API_KEY": "placeholder-value"])
    }
}
