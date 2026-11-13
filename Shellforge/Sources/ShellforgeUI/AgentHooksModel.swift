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

    /// Whether Claude Code's status line is Shellforge's runnable shim, so Claude's rate limits reach
    /// the footer — read from the status line at each check, as AiTerm reads it. True until the
    /// first check, so the footer never flashes "Usage disconnected" at launch; the app checks at
    /// launch (`iTermShellforgeSidebar.startHelper`).
    @Published public private(set) var claudeStatusLineInstalled = true
    /// The last install's failure, in the installer's words; cleared by the next success.
    @Published public private(set) var lastError: String?

    private let integrations: HookIntegrations
    /// Asks a development build's person before an install for this build; the app sets the modal one.
    public var prompter: Prompter = NullPrompter()

    /// Told whether any of this build's hooks still post without the helper's token: after the
    /// launch's upgrade and after each install. The app passes it on to the helper.
    public var onTokenless: (@MainActor (Bool) -> Void)?

    /// A development build's sheet: it shows the installed app's hooks, and installs only for this
    /// build, once confirmed.
    public var isSharedWithInstalledApp: Bool { integrations.isSharedWithInstalledApp }

    public init(integrations: HookIntegrations, names: [String: String]) {
        self.integrations = integrations
        rows = integrations.agents.map { Row(id: $0, name: names[$0] ?? $0, probe: HookProbe(state: .notChecked, explanation: nil), working: false) }
    }

    /// Probes every agent.
    public func refresh() async {
        let integrations = self.integrations
        let (probes, statusLine) = await BackgroundWork.run {
            (integrations.agents.map { ($0, integrations.probe($0)) }, integrations.claudeStatusLineIsInstalled())
        }
        for (agent, probe) in probes { update(agent) { $0.probe = probe } }
        if claudeStatusLineInstalled != statusLine { claudeStatusLineInstalled = statusLine }
    }

    /// The launch's pass: rewrites the hooks an install made before they carried the helper's token,
    /// exactly as they were otherwise (`HookIntegrations.upgradeTokenlessInstalls`), then probes.
    public func upgradeTokenlessInstalls() async {
        let integrations = self.integrations
        let remain = await BackgroundWork.run { integrations.upgradeTokenlessInstalls() }
        await refresh()
        onTokenless?(remain)
    }

    /// Installs or repairs one agent's hooks, then reads them again. A development build asks first,
    /// and installs for this build only on a yes.
    public func install(_ agent: String) async {
        let forThisBuild = isSharedWithInstalledApp
        if forThisBuild {
            let name = rows.first { $0.id == agent }?.name ?? agent
            let answer = await prompter.ask(Self.installForThisBuildPrompt(name: name))
            guard answer.confirmed else { return }
        }
        update(agent) { $0.working = true }
        let integrations = self.integrations
        let outcome = await BackgroundWork.run { () -> (Result<Void, Error>, HookProbe, Bool, Bool) in
            let result = Result { try integrations.install(agent, forThisBuild: forThisBuild) }
            return (result, integrations.probe(agent), integrations.claudeStatusLineIsInstalled(), integrations.postsWithoutToken())
        }
        onTokenless?(outcome.3)
        update(agent) { $0.working = false; $0.probe = outcome.1 }
        if claudeStatusLineInstalled != outcome.2 { claudeStatusLineInstalled = outcome.2 }
        switch outcome.0 {
        case .success: lastError = nil
        case .failure(let error): lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// The question before a development build points an agent's shared hooks at itself.
    static func installForThisBuildPrompt(name: String) -> AlertPrompt {
        AlertPrompt(message: "Install \(name)’s hooks for this build?",
                    detail: "\(name)’s hooks are shared with the installed Shellforge. Installing them here points them at this development build, so the installed Shellforge stops showing working and done until you repair them from there.",
                    buttons: [AgentHooksView.installForThisBuildTitle, "Cancel"])
    }

    private func update(_ agent: String, _ change: (inout Row) -> Void) {
        guard let index = rows.firstIndex(where: { $0.id == agent }) else { return }
        change(&rows[index])
    }
}
