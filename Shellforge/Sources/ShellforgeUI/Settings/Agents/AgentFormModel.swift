import Combine
import Foundation
import ShellforgeCore

/// Settings › Agents' form, for a new agent or an existing one: its name, command, how the first
/// prompt gets in, its environment and secrets, and how its status is detected. What is wrong is
/// worked out from the fields as they are typed; Save writes the agent's file, then its secrets to
/// the Keychain. A secret's value is never read back into the form.
@MainActor
public final class AgentFormModel: ObservableObject {
    public enum PromptMode: CaseIterable, Hashable, Sendable {
        case argument, typed, none

        public var title: String {
            switch self {
            case .argument: "As an argument"
            case .typed: "Typed in after it starts"
            case .none: "None"
            }
        }

        init(_ delivery: AgentDefinition.PromptDelivery) {
            switch delivery {
            case .argument: self = .argument
            case .typed: self = .typed
            // Shellforge can't pass a prompt on standard input, so such an agent starts without one.
            case .noPrompt, .stdin: self = .none
            }
        }

        var delivery: AgentDefinition.PromptDelivery {
            switch self {
            case .argument: .argument
            case .typed: .typed
            case .none: .noPrompt
            }
        }
    }

    public enum StatusMode: CaseIterable, Hashable, Sendable {
        case automatic, exact

        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .exact: "Exact"
            }
        }
    }

    public struct Variable: Identifiable, Equatable {
        public var id: UUID
        public var name: String
        public var value: String
        public init(id: UUID = UUID(), name: String, value: String) { self.id = id; self.name = name; self.value = value }
    }

    /// A secret: `value` is what is typed, never what the Keychain holds. `stored` says the Keychain
    /// holds one, which an empty `value` keeps.
    public struct Secret: Identifiable, Equatable {
        public var id: UUID
        public var name: String
        public var value: String
        public var stored: Bool
        public init(id: UUID = UUID(), name: String, value: String, stored: Bool) {
            self.id = id; self.name = name; self.value = value; self.stored = stored
        }
    }

    /// The agent's file was saved, and a secret wasn't: the form stays open, the value in it.
    public struct KeychainRefused: Error, Equatable, LocalizedError {
        public let variable: String
        public var errorDescription: String? { "Shellforge couldn’t keep \(variable) in the Keychain. Enter it again and click Save." }
    }

    /// A save that went no further, `cause` saying why, whose undoing the Keychain refused for
    /// `variables`: they may hold what this save wrote. Names only, never a value.
    public struct NotPutBack: Error, Equatable, LocalizedError {
        public let cause: String
        public let variables: [String]
        public var errorDescription: String? {
            let pronoun = variables.count == 1 ? "it" : "them"
            let notPutBack = "Shellforge couldn’t put back \(AgentListModel.listed(variables)) in the Keychain. Check \(pronoun) in the agent’s form."
            // The cause is another error's sentence, which may not end with a full stop of its own.
            let trimmed = cause.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let end = trimmed.last else { return notPutBack }
            return trimmed + (".!?…".contains(end) ? " " : ". ") + notPutBack
        }
    }

    /// Save with a field still wrong: the field's own sentence.
    public struct Incomplete: Error, Equatable, LocalizedError {
        public let problem: String
        public var errorDescription: String? { problem }
    }

    @Published public var name: String
    @Published public var command: String
    @Published public var promptMode: PromptMode
    @Published public var promptArguments: String
    @Published public var environment: [Variable]
    @Published public var secrets: [Secret]
    @Published public var status: StatusMode
    @Published public private(set) var testMessage: String?

    public let origin: AgentRegistry.Origin
    /// The form's title: Add Agent, or Edit and the agent's name as it was opened.
    public let title: String
    /// The agent as last saved, or opened; nil for a new agent until its first Save.
    private var base: AgentDefinition?
    /// Every other agent: a name must differ from theirs, and a new id from their ids.
    private let others: [AgentDefinition]
    private let list: AgentListModel
    private let sessions: () -> [SessionInfo]
    private let openedAt: Date
    /// The fields as `base` has them: a field left as it was keeps what `base` holds.
    private var saved: (command: String, prompt: String, promptMode: PromptMode, status: StatusMode)
    /// Each stored secret's name in the Keychain, by row, so a renamed one moves its item.
    private var storedNames: [UUID: String] = [:]

    init(agent: AgentDefinition?, origin: AgentRegistry.Origin, others: [AgentDefinition], list: AgentListModel,
         sessions: @escaping () -> [SessionInfo], openedAt: Date) {
        base = agent
        self.origin = origin
        title = agent.map { "Edit “\($0.name)”" } ?? "Add Agent"
        self.others = others
        self.list = list
        self.sessions = sessions
        self.openedAt = openedAt
        let command = agent?.commandText ?? "", prompt = agent?.promptArgumentsText ?? AgentDefinition.promptPlaceholder
        let promptMode = PromptMode(agent?.prompt ?? .argument), status: StatusMode = agent?.status == .eventProtocol ? .exact : .automatic
        name = agent?.name ?? ""
        self.command = command
        self.promptMode = promptMode
        promptArguments = prompt
        environment = (agent?.environment ?? [:]).sorted { $0.key < $1.key }.map { Variable(name: $0.key, value: $0.value) }
        let stored = (agent?.secrets.keys.sorted() ?? []).map { Secret(name: $0, value: "", stored: true) }
        secrets = stored
        self.status = status
        saved = (command, prompt, promptMode, status)
        for secret in stored { storedNames[secret.id] = secret.name }
    }

    // MARK: - What is wrong

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var nameProblem: String? {
        let name = trimmedName
        if name.isEmpty { return "Give the agent a name." }
        let taken = others.contains { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
        return taken ? "Another agent is already called “\(name)”." : nil
    }

    public var commandProblem: String? {
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the command that starts the agent." }
        guard let parsed = AgentDefinition.parseCommand(command) else { return "The command has an unclosed quote." }
        if let unsafe = AgentDefinition(id: "", name: "", command: parsed.command, arguments: parsed.arguments).unsafeWord() {
            return unsafe.errorDescription
        }
        guard list.launcher.locate(parsed.command) != nil else {
            return AgentNotInstalled(agent: trimmedName.isEmpty ? parsed.command : trimmedName).errorDescription
        }
        return nil
    }

    public var promptProblem: String? {
        guard promptMode == .argument else { return nil }
        guard let groups = AgentDefinition.parseArguments(promptArguments) else { return "The command has an unclosed quote." }
        guard promptArguments.contains(AgentDefinition.promptPlaceholder) else {
            return "Put {prompt} where the prompt goes, for example -p {prompt}."
        }
        return AgentDefinition(id: "", name: "", command: "", arguments: groups).unsafeWord()?.errorDescription
    }

    public var variableProblem: String? {
        let rows = environment.filter { !$0.name.isEmpty || !$0.value.isEmpty }.map { (name: $0.name, value: $0.value, plain: true) }
            + secrets.filter { !isBlank($0) }.map { (name: $0.name, value: $0.value, plain: false) }
        var seen: Set<String> = []
        for row in rows {
            if row.name.isEmpty, !row.value.isEmpty { return "A variable has a value but no name." }
            if row.name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
                return "“\(row.name)” isn’t a valid variable name."
            }
            if !seen.insert(row.name).inserted { return "“\(row.name)” is set twice." }
            if row.plain, !row.value.isEmpty, AgentRegistry.looksSecret(row.name) {
                return "“\(row.name)” looks like a secret. Move it to Secrets, so it’s kept in the Keychain."
            }
        }
        if let empty = secrets.first(where: { !$0.name.isEmpty && $0.value.isEmpty && !$0.stored }) {
            return "Enter a value for \(empty.name)."
        }
        return nil
    }

    private func isBlank(_ secret: Secret) -> Bool { secret.name.isEmpty && secret.value.isEmpty && !secret.stored }

    public var canSave: Bool {
        nameProblem == nil && commandProblem == nil && promptProblem == nil && variableProblem == nil
    }

    // MARK: - What it shows

    /// What the agent is, for a ready-made agent that says.
    public var about: String? { base?.about }

    /// A built-in's status is its own; every other agent's can be Exact.
    public var showsStatusChoice: Bool { origin != .builtIn }

    private var showsExact: Bool { showsStatusChoice && status == .exact }

    /// The lines to add to the agent's settings for Exact status, with the full path of the
    /// bundled `shellforge-status` in them; none while the app runs from a temporary copy.
    public var setupLines: String? {
        guard showsExact, !list.tools.translocated, let statusCommand = list.tools.statusCommand else { return nil }
        let setup = AgentDefinition(id: "", name: "", command: "", statusSetup: base?.statusSetup)
        return ExactStatusLines.lines(for: setup, statusCommand: statusCommand)
    }

    /// The settings file the lines go in, for an agent that names one.
    public var setupFile: String? { showsExact ? base?.statusSetup?.file : nil }

    /// What to mind when adding the lines, for an agent that says.
    public var setupNote: String? { showsExact ? base?.statusSetupNote : nil }

    /// Why there are no lines: a path into a temporary copy of the app is gone once it quits.
    public var setupWarning: String? { showsExact && list.tools.translocated ? BundleLocation.translocationWarning : nil }

    /// The line a task would type to start the agent, with a sample prompt; nil while the command
    /// can't be read or typed.
    public var preview: String? {
        guard let agent = draft() else { return nil }
        let model: String
        if case .fixed(let models) = agent.models { model = models.first ?? "" } else { model = "" }
        return try? AgentLaunch.previewCommand(agent: agent, model: model, reasoning: agent.defaultReasoning,
                                               prompt: agent.prompt == .argument ? "Your prompt" : nil, runner: list.tools.runner)
    }

    /// The id the agent has, or will have once saved.
    private var agentId: String {
        base?.id ?? AgentRegistry.freshId(for: trimmedName, taken: Set(others.map(\.id)))
    }

    /// Whether a report has come from a tab running this agent since the form opened.
    public func test() {
        let agent = SessionAgent(agentId: agentId), since = openedAt.timeIntervalSince1970
        let arrived = sessions().contains { $0.agent == agent && ($0.reportedAt.map { $0 >= since } ?? false) }
        testMessage = arrived ? "A report arrived from a task with this agent."
            : "No report yet. Start a task with this agent and let its hooks run."
    }

    // MARK: - Saving

    /// The agent the fields describe, over everything `base` holds that the form doesn't show.
    /// A field left as it was keeps `base`'s value as it was, its groups in their order.
    private func draft() -> AgentDefinition? {
        let id = agentId
        var agent = base ?? AgentDefinition(id: id, name: "", command: "")
        agent.name = trimmedName
        let commandKept = base != nil && command == saved.command
        let promptKept = base != nil && promptMode == saved.promptMode && (promptMode != .argument || promptArguments == saved.prompt)
        if !(commandKept && promptKept) {
            var commandPart = (command: agent.command, groups: agent.commandGroups)
            if !commandKept {
                guard let parsed = AgentDefinition.parseCommand(command) else { return nil }
                commandPart = (parsed.command, parsed.arguments)
            }
            var promptGroups: [[String]] = []
            if promptMode == .argument {
                if base != nil, promptArguments == saved.prompt {
                    promptGroups = agent.promptGroups
                } else if promptArguments.trimmingCharacters(in: .whitespaces) != AgentDefinition.promptPlaceholder {
                    // `{prompt}` alone is the prompt last, which no group says.
                    guard let groups = AgentDefinition.parseArguments(promptArguments) else { return nil }
                    promptGroups = groups
                }
            }
            agent.command = commandPart.command
            agent.arguments = commandPart.groups + promptGroups
        }
        if !(base != nil && promptMode == saved.promptMode) { agent.prompt = promptMode.delivery }
        agent.environment = Dictionary(environment.filter { !$0.name.isEmpty }.map { ($0.name, $0.value) }) { _, last in last }
        agent.secrets = Dictionary(secrets.filter { !$0.name.isEmpty }.map { ($0.name, item(of: $0, id: id)) }) { _, last in last }
        if showsStatusChoice, !(base != nil && status == saved.status) {
            agent.status = status == .exact ? .eventProtocol : .terminal
        }
        return agent
    }

    /// The Keychain entry a secret row is saved under. A row left as it was keeps the entry its file
    /// names (a hand-written file may name its own); one typed or renamed goes under the form's,
    /// `agent.<id>.<VARIABLE>`, where `save` writes it.
    private func item(of secret: Secret, id: String) -> String {
        if secret.value.isEmpty, storedNames[secret.id] == secret.name, let base { return AgentSecrets.item(of: base, variable: secret.name) }
        return AgentSecrets.key(agent: id, variable: secret.name)
    }

    /// Writes each secret typed, and each renamed secret's value under its new name, to the
    /// Keychain, then the agent's file — a new agent's with `create`, so it can't take a reserved or
    /// taken id; any other's with `save`, which for a built-in or ready-made agent makes an override
    /// and deletes the items of the secrets it no longer names, a renamed one's old item among them.
    /// The Keychain goes first, so a value it refuses is never lost: the file is left as it was,
    /// still naming the old item, and the row says whether the Keychain holds one under its name.
    /// Throws the first field's problem, the secret the Keychain wouldn't keep, or the registry's
    /// refusal; nothing is reported saved unless all of it was.
    public func save() throws {
        if let problem = nameProblem ?? commandProblem ?? promptProblem ?? variableProblem { throw Incomplete(problem: problem) }
        guard let agent = draft() else { throw Incomplete(problem: "The command has an unclosed quote.") }
        let store = list.secrets
        let key = { (variable: String) in AgentSecrets.key(agent: agent.id, variable: variable) }
        // Every value to write, read before anything is written: in a chain of renames (A→B, B→C)
        // or a swap (A↔B) a row's old item is another row's new one.
        let plan: [(index: Int, value: String)] = secrets.indices.compactMap { index in
            let secret = secrets[index]
            guard !secret.name.isEmpty else { return nil }
            if !secret.value.isEmpty { return (index, secret.value) }
            guard let old = storedNames[secret.id], old != secret.name,
                  let value = store.get(base.map { AgentSecrets.item(of: $0, variable: old) } ?? key(old)) else { return nil }
            return (index, value)
        }
        // What each item to be written holds now — nil for none — so a save that goes no further
        // puts every one back as it was, an item that was there before included.
        let before = Dictionary(plan.map { (key(secrets[$0.index].name), store.get(key(secrets[$0.index].name))) }) { first, _ in first }
        // The items written, by variable: only those have anything to put back.
        var touched: [(item: String, variable: String)] = []
        /// Puts every item written back as it was, and throws `failure` — or, when the Keychain
        /// refuses to put one back, `NotPutBack` naming those.
        func rollBack(_ failure: Error) -> Error {
            let stuck = touched.filter { !store.set($0.item, before[$0.item] ?? nil) }.map(\.variable)
            return stuck.isEmpty ? failure : NotPutBack(cause: failure.localizedDescription, variables: stuck)
        }
        for step in plan {
            let name = secrets[step.index].name
            guard store.set(key(name), step.value) else {
                secrets[step.index].stored = storedNames[secrets[step.index].id] == name
                throw rollBack(KeychainRefused(variable: name))
            }
            touched.append((key(name), name))
        }
        let written = Set(plan.map { secrets[$0.index].id })
        do {
            if base == nil { try list.registry.create(agent, secrets: store) } else { try list.registry.save(agent, secrets: store) }
        } catch {
            throw rollBack(error)
        }
        for index in secrets.indices where written.contains(secrets[index].id) {
            secrets[index].value = ""
            secrets[index].stored = true
            storedNames[secrets[index].id] = secrets[index].name
        }
        base = agent
        saved = (command, promptArguments, promptMode, status)
        list.formSaved()
    }
}
