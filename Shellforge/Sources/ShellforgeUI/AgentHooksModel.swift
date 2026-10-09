import Foundation
import ShellforgeCore

/// What the Agent hooks sheet shows: each preset agent's hooks and whether its button is working.
/// Every read and write of the user's files runs off the main thread.
@MainActor
public final class AgentHooksModel: ObservableObject {
    public struct Row: Identifiable, Equatable {
        public let id: String
        public let name: String
        public var probe: HookProbe
        public var working: Bool
    }

    @Published public private(set) var rows: [Row]
    /// The last install's failure, in the installer's words; cleared by the next success.
    @Published public private(set) var lastError: String?

    private let integrations: HookIntegrations

    public init(integrations: HookIntegrations, names: [String: String]) {
        self.integrations = integrations
        rows = integrations.agents.map { Row(id: $0, name: names[$0] ?? $0, probe: HookProbe(state: .notChecked, explanation: nil), working: false) }
    }

    /// Probes every agent.
    public func refresh() async {
        let integrations = self.integrations
        let probes = await BackgroundWork.run { integrations.agents.map { ($0, integrations.probe($0)) } }
        for (agent, probe) in probes { update(agent) { $0.probe = probe } }
    }

    /// Installs or repairs one agent's hooks, then reads them again.
    public func install(_ agent: String) async {
        update(agent) { $0.working = true }
        let integrations = self.integrations
        let outcome = await BackgroundWork.run { () -> (Result<Void, Error>, HookProbe) in
            let result = Result { try integrations.install(agent) }
            return (result, integrations.probe(agent))
        }
        update(agent) { $0.working = false; $0.probe = outcome.1 }
        switch outcome.0 {
        case .success: lastError = nil
        case .failure(let error): lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    private func update(_ agent: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == agent }) else { return }
        change(&rows[index])
    }
}
