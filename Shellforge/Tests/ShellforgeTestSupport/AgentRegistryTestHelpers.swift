import ShellforgeCore

/// The registry calls that need a secret store, for a test that has no secrets to care about.
public extension AgentRegistry {
    func save(_ agent: AgentDefinition) throws { try save(agent, secrets: MemorySecretStore()) }
    func remove(id: String) throws { try remove(id: id, secrets: MemorySecretStore()) }
    @discardableResult func duplicate(id: String) throws -> AgentDefinition { try duplicate(id: id, secrets: MemorySecretStore()) }
    func create(_ agent: AgentDefinition) throws { try create(agent, secrets: MemorySecretStore()) }
}
