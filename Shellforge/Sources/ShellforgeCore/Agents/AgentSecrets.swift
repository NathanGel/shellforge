import Foundation

/// An agent's secrets, which live in the Keychain and nowhere else: not in its file, a log or the
/// command typed into a tab. Each is one entry of the app's Keychain item, under the name the
/// agent's file gives it (`AgentDefinition.secrets`); the form writes `agent.<id>.<VARIABLE>`, and a
/// file that gives no name means that one.
public enum AgentSecrets {
    /// Every agent's entries start with this, and no other feature's do.
    public static let namespace = "agent."

    public static func key(agent: String, variable: String) -> String { "\(namespace)\(agent).\(variable)" }

    /// The entry `variable`'s value is read from: the file's own name for it, else the form's. A name
    /// outside `namespace` counts as none, so an agent's file can never read another feature's entry
    /// (a Jira, GitLab or GitHub token, the Backpack password) into an agent's environment.
    public static func item(of agent: AgentDefinition, variable: String) -> String {
        guard let named = agent.secrets[variable], named.hasPrefix(namespace), named.count > namespace.count else {
            return key(agent: agent.id, variable: variable)
        }
        return named
    }

    /// A secret the agent names that the Keychain doesn't hold. The sentence names the variable,
    /// never a value.
    public struct Missing: Error, Equatable, LocalizedError {
        public let agent: String
        public let variable: String
        public var errorDescription: String? { "\(agent)’s secret \(variable) isn’t in the Keychain. Set it again in Settings › Agents." }
    }

    /// The environment the agent starts with: its plain variables, then each secret's value.
    public static func environment(for agent: AgentDefinition, store: any SecretStore) throws -> [String: String] {
        var environment = agent.environment
        for variable in agent.secrets.keys.sorted() {
            guard let value = store.get(item(of: agent, variable: variable)), !value.isEmpty else {
                throw Missing(agent: agent.name, variable: variable)
            }
            environment[variable] = value
        }
        return environment
    }

    /// Deletes the Keychain entries the form wrote for the agent's secrets, and no other agent's or
    /// feature's: an entry a hand-written file names may be shared, so it stays. The store can't list
    /// its keys, so these are the variables `agent.secrets` names.
    public static func removeAll(for agent: AgentDefinition, store: any SecretStore) {
        for variable in agent.secrets.keys {
            store.set(key(agent: agent.id, variable: variable), nil)
        }
    }
}
