import Combine
import Foundation
import ShellforgeCore

/// Settings › Agents' list: the built-ins, the ready-made agents and the person's own, each with
/// whether its command is installed and how its status is detected; and what can be done to each —
/// Edit, Duplicate, Remove or Restore Default. Every change goes to the agents folder and the
/// Keychain at once, and `changed` tells the app to read the agents again.
@MainActor
public final class AgentListModel: ObservableObject {
    public struct Row: Identifiable, Equatable {
        public var agent: AgentDefinition
        public var origin: AgentRegistry.Origin
        /// A saved file replaces this built-in or ready-made agent: Restore Default removes it.
        public var overridden: Bool
        /// Its command is on the login shell's `PATH`.
        public var installed: Bool
        public var detection: Detection
        public var id: String { agent.id }
    }

    /// Where a row's status comes from.
    public enum Detection: Equatable, Sendable {
        /// A built-in's own hooks and logs.
        case builtIn
        /// Guessed from its terminal.
        case automatic
        /// Reported by its hooks through `shellforge-status`.
        case exact

        public var label: String {
            switch self {
            case .builtIn: "Built-in status"
            case .automatic: "Automatic status"
            case .exact: "Exact status"
            }
        }
    }

    @Published public private(set) var rows: [Row] = []
    /// The last change that didn't go through, or the agent files that couldn't be read.
    @Published public var failure: String?

    let registry: AgentRegistry
    let secrets: any SecretStore
    let launcher: CommandLauncher
    let tools: AgentTools
    private let tasks: @MainActor () -> [TaskItem]
    private let prompter: any Prompter
    private let now: () -> Date
    private let changed: @MainActor () -> Void
    /// The sessions as the helper last said, for the form's Test.
    private var latest = SessionStore()
    private var subscription: AnyCancellable?

    /// `secrets` is where the agents' secrets are kept: the app's is `Keychain.shared`. `tasks` names
    /// the tasks Remove would leave without their agent; `store` is the helper's sessions, for Test.
    public init(registry: AgentRegistry, secrets: any SecretStore, launcher: CommandLauncher,
                tasks: @escaping @MainActor () -> [TaskItem], prompter: any Prompter, tools: AgentTools,
                store: AnyPublisher<SessionStore, Never>, now: @escaping () -> Date = Date.init,
                changed: @escaping @MainActor () -> Void) {
        self.registry = registry
        self.secrets = secrets
        self.launcher = launcher
        self.tasks = tasks
        self.prompter = prompter
        self.tools = tools
        self.now = now
        self.changed = changed
        subscription = store.receive(on: DispatchQueue.main).sink { [weak self] store in MainActor.assumeIsolated { self?.latest = store } }
        reload()
    }

    /// Reads the agents again. Whether each is installed comes from the environment as read so far:
    /// before the login shell's first read is done, a row keeps what it showed (not installed when
    /// new), the read finishes off the main actor, and the list is read again then.
    public func reload() {
        var waiting = false
        do {
            let loaded = try registry.load()
            let before = Dictionary(rows.map { ($0.id, $0.installed) }) { first, _ in first }
            rows = loaded.agents.map { agent in
                let origin = loaded.origins[agent.id] ?? .own
                let installed = launcher.isInstalledIfKnown(agent.command)
                if installed == nil { waiting = true }
                return Row(agent: agent, origin: origin, overridden: loaded.overridden.contains(agent.id),
                           installed: installed ?? before[agent.id] ?? false, detection: Self.detection(agent, origin: origin))
            }
            failure = AgentFiles.problemSentence(files: loaded.problems.map(\.file))
        } catch {
            failure = error.localizedDescription
        }
        if waiting { readEnvironment() }
    }

    /// The login shell's first read, running off the main actor; one at a time.
    private var readingEnvironment = false

    private func readEnvironment() {
        guard !readingEnvironment else { return }
        readingEnvironment = true
        let launcher = self.launcher
        Task { [weak self] in
            _ = await BackgroundWork.run { launcher.environment }
            guard let self else { return }
            self.readingEnvironment = false
            self.reload()
        }
    }

    private static func detection(_ agent: AgentDefinition, origin: AgentRegistry.Origin) -> Detection {
        if origin == .builtIn { return .builtIn }
        switch agent.status {
        case .preset: return .builtIn
        case .eventProtocol: return .exact
        case .openTelemetry, .terminal: return .automatic
        }
    }

    /// The form for a new agent of the person's own, empty.
    public func addForm() -> AgentFormModel { form(for: nil, origin: .own) }

    /// The form for the agent `id`. Saved, a built-in or ready-made agent becomes an override.
    public func editForm(_ id: String) -> AgentFormModel {
        guard let row = rows.first(where: { $0.id == id }) else { return addForm() }
        return form(for: row.agent, origin: row.origin)
    }

    private func form(for agent: AgentDefinition?, origin: AgentRegistry.Origin) -> AgentFormModel {
        AgentFormModel(agent: agent, origin: origin, others: rows.map(\.agent).filter { $0.id != agent?.id },
                       list: self, sessions: { [weak self] in self.map { Array($0.latest.sessions.values) } ?? [] }, openedAt: now())
    }

    /// A form saved: the list reads the agents again and the app is told.
    func formSaved() {
        reload()
        changed()
    }

    /// Copies the agent into a new agent of the person's own, with its secrets, so the copy starts
    /// as the original does.
    public func duplicate(_ id: String) {
        // Said after the list is read again, which would otherwise clear it.
        var refused: String?
        do {
            let copy = try registry.duplicate(id: id, secrets: secrets)
            for variable in copy.secrets.keys.sorted() {
                guard let value = secrets.get(AgentSecrets.key(agent: id, variable: variable)) else { continue }
                if !secrets.set(AgentSecrets.key(agent: copy.id, variable: variable), value), refused == nil {
                    refused = variable
                }
            }
        } catch {
            failure = error.localizedDescription
            return
        }
        formSaved()
        if let refused {
            failure = "The copy was made, but Shellforge couldn’t copy \(refused) to the Keychain. Set it in the copy’s form."
        }
    }

    /// Asks, naming the tasks that use it, then removes the person's own agent and its secrets.
    public func remove(_ id: String) async {
        guard let name = rows.first(where: { $0.id == id })?.agent.name else { return }
        let titles = tasks().filter { $0.agent == id }.map(\.title)
        let detail = titles.isEmpty ? "No task uses it."
            : "These tasks use it: \(Self.listed(titles)). They stay in the sidebar, but can’t start \(name) again."
        let answer = await prompter.ask(AlertPrompt(message: "Remove “\(name)”?", detail: detail, buttons: ["Remove", "Cancel"],
                                                    defaultDeletes: true))
        guard answer.confirmed else { return }
        removeFile(id)
    }

    /// Asks, then removes the override of a built-in or ready-made agent, and its secrets.
    public func restoreDefault(_ id: String) async {
        guard let name = rows.first(where: { $0.id == id })?.agent.name else { return }
        let answer = await prompter.ask(AlertPrompt(message: "Restore “\(name)” to its default?",
                                                    detail: "Your changes to its command, environment and secrets are removed.",
                                                    buttons: ["Restore Default", "Cancel"]))
        guard answer.confirmed else { return }
        removeFile(id)
    }

    private func removeFile(_ id: String) {
        do {
            try registry.remove(id: id, secrets: secrets)
        } catch {
            failure = error.localizedDescription
            return
        }
        formSaved()
    }

    /// “A”, “A and B”, “A, B and C”.
    nonisolated static func listed(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }
}
