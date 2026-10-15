// Ported from AiTerm (app/Sources/AiTerm/CreationModel.swift, TaskCreationModel.swift and Views/Steps/AgentStep.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// Why the last create failed: `reason` is what the footer always shows, `detail` everything else
/// that was said — for a git failure, the command and its whole output, in the tooltip.
public struct CreationFailure: Equatable {
    public let reason: String
    public let detail: String?

    public init(reason: String, detail: String?) { self.reason = reason; self.detail = detail }

    /// A git failure says its last line of complaint — git's own reason — and keeps the rest for
    /// the tooltip; any other error says its own description.
    public init(_ error: Error) {
        if let failure = error as? GitFailure {
            let lines = failure.message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            reason = lines.last(where: { !$0.isEmpty }) ?? failure.description
            detail = failure.description
        } else {
            reason = error.localizedDescription
            detail = nil
        }
    }
}

/// What a creation sheet is for — New Task or New Review — and what that changes: AiTerm's
/// `CreationKind`. The rest of `CreationModel` is the same for both.
/// A class, as AiTerm's is: a kind can keep state of its own — New Review's pick refusal and branch
/// filter — which its model's methods change, announcing the change on the model.
@MainActor
public protocol CreationKind: AnyObject {
    associatedtype Draft: AgentDraft
    /// What the sheet's search field lists: a Jira ticket, a merge request.
    associatedtype Item: Identifiable & Equatable
    /// The worktree directory the draft wants, before an unused one is found.
    func slug(of draft: Draft) -> String
    /// The agent's first prompt, as the command will carry it.
    func prompt(of draft: Draft) -> String?
    /// Whether the first step is filled in enough to go on.
    func firstStepDone(_ draft: Draft) -> Bool
    /// The project's branches, once read: what the draft takes from them, given the draft it opened with.
    func branchesLoaded(_ found: [String], into draft: inout Draft, opened: Draft)
}

/// New Task: a ticket, a new branch from a base, and the ticket's details in the prompt.
public final class TaskCreation: CreationKind {
    public typealias Draft = TaskDraft
    public typealias Item = JiraTicket
    /// The project's SSH host, while the config has it: New Task offers it as a pane beside the agent.
    public let sshHost: String?
    /// The project's worktrees New Task can continue in, as last read (`loadExistingWorktrees`).
    public internal(set) var existing: [ExistingWorktree] = []
    let listExisting: @Sendable () -> [ExistingWorktree]
    public init(sshHost: String? = nil, listExisting: @escaping @Sendable () -> [ExistingWorktree] = { [] }) {
        self.sshHost = sshHost; self.listExisting = listExisting
    }
    /// An existing worktree makes none: nothing to name.
    public func slug(of draft: TaskDraft) -> String { draft.useExisting ? "" : draft.worktreeSlug }
    public func prompt(of draft: TaskDraft) -> String? {
        AgentCommand.composePrompt(userText: draft.promptText, ticket: draft.ticket, appendTicket: draft.appendTicket)
    }
    public func firstStepDone(_ draft: TaskDraft) -> Bool {
        !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!draft.useExisting || draft.existing != nil)
    }
    /// The base the draft opened with is replaced by the repository's default, unless the person
    /// picked another meanwhile.
    public func branchesLoaded(_ found: [String], into draft: inout TaskDraft, opened: TaskDraft) {
        if draft.baseBranch == opened.baseBranch, let first = found.first { draft.baseBranch = first }
    }
}

/// New Task's model, as every caller names it.
public typealias NewTaskModel = CreationModel<TaskCreation>

/// A creation sheet's state: the draft, the chosen agent's models, the project's branches, the
/// search field, and the one create call. AiTerm's `CreationModel` on an `ObservableObject` (macOS 13
/// has no `@Observable`).
/// What a create's work hears from the sheet that started it: its Cancel, and where to say what it
/// is doing. Task-locals, so the submit closure keeps its shape; read them on the main actor before
/// handing the work to a background queue, which they do not follow.
public enum CreationContext {
    @TaskLocal public static var cancellation: CreationCancellation?
    @TaskLocal public static var report: (@Sendable (CreationStep) -> Void)?
}

@MainActor
public final class CreationModel<Kind: CreationKind>: ObservableObject, Identifiable {
    public nonisolated let id = UUID()
    /// What the sheet is for, with whatever state of its own that keeps.
    public let kind: Kind
    public let project: Project
    public let agents: [AgentDefinition]
    @Published public var draft: Kind.Draft
    @Published public private(set) var branches: [String] = []
    @Published public private(set) var models: [AgentModel] = []
    @Published public private(set) var catalogueLoaded = false
    /// Why the chosen agent has no models to offer, when its list could not be read.
    @Published public private(set) var catalogueFailure: String?
    @Published public private(set) var creating = false
    /// What the running create is doing, as its work says; nil before it says.
    @Published public private(set) var progress: CreationStep?
    /// Cancel was pressed while it ran: it is stopping and undoing what it made.
    @Published public private(set) var cancelling = false
    /// The last create was cancelled — not failed: the sheet closes, saying nothing.
    @Published public private(set) var cancelled = false
    @Published public private(set) var error: CreationFailure?
    private var cancellation: CreationCancellation?
    /// The search field — a ticket's, a merge request's: what is typed, what the last search found,
    /// and why it found nothing.
    @Published public var query = ""
    @Published public private(set) var results: [Kind.Item] = []
    /// Whether the list hangs open under its field. AiTerm keeps this in the sheet; here the model
    /// holds it, so the ways it closes — ⎋, a click past it, leaving the step — are testable.
    @Published public var listOpen = false
    @Published public internal(set) var searchError: String?
    private let searchItems: @MainActor (String) async throws -> [Kind.Item]
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    /// The agent's commands and skills for the prompt's `/` popup, read with its models.
    public let completions = PromptCompletions()
    /// Whose skills and commands the prompt completes.
    private let home: URL
    /// The agents whose CLIs the login shell finds, read when the sheet opens.
    public let availableAgents: Set<String>

    private let rememberedModels: [String: String]
    private let catalogue: @Sendable (AgentDefinition) throws -> [AgentModel]
    private let listBranches: @Sendable () -> [String]
    private let submit: @MainActor (Kind.Draft) async throws -> Void
    private var catalogueGeneration = 0
    private var resetModel = false
    /// The draft as the sheet opened with it, for what the branches, once read, may replace.
    private let opened: Kind.Draft
    /// `worktreeSlug` stats the worktree directory; remembered per slug so a redraw does not.
    private var unusedSlugMemo: (slug: String, unused: String)?

    public init(kind: Kind, project: Project, agents: [AgentDefinition], available: Set<String>, draft: Kind.Draft,
                rememberedModels: [String: String],
                catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel],
                branches: @escaping @Sendable () -> [String],
                submit: @escaping @MainActor (Kind.Draft) async throws -> Void,
                search: @escaping @MainActor (String) async throws -> [Kind.Item] = { _ in [] },
                home: URL) {
        self.kind = kind
        self.home = home
        self.searchItems = search
        self.project = project
        self.agents = agents
        self.availableAgents = available
        self.draft = draft
        self.opened = draft
        self.rememberedModels = rememberedModels
        self.catalogue = catalogue
        self.listBranches = branches
        self.submit = submit
    }

    /// The draft's agent; the first one when the draft names none the sheet knows.
    public var agent: AgentDefinition { agents.first { $0.id == draft.agentId } ?? agents[0] }

    /// The worktree directory the sheet names: the one create will make.
    public var worktreeSlug: String {
        let slug = kind.slug(of: draft)
        guard !slug.isEmpty else { return "" }
        if let memo = unusedSlugMemo, memo.slug == slug { return memo.unused }
        let unused = BranchNaming.unused(slug, in: project.path)
        unusedSlugMemo = (slug, unused)
        return unused
    }

    /// The exact command the task will run, built without touching the disk.
    public var previewCommand: String {
        AgentCommand.previewCommand(agent: agent, model: draft.model, reasoning: draft.reasoning,
                                    prompt: kind.prompt(of: draft))
    }

    public var selectedModelIsCurrent: Bool { catalogueLoaded && models.contains { $0.id == draft.model } }

    /// Whether the draft's agent can run: its CLI is installed and its model is one the catalogue
    /// still offers.
    public var agentIsReady: Bool { availableAgents.contains(draft.agentId) && selectedModelIsCurrent }

    /// Step 1 needs what its kind asks — a name, for a task; the agent and prompt steps need an
    /// agent that can run.
    public func canAdvance(step: Int) -> Bool {
        guard !creating, kind.firstStepDone(draft) else { return false }
        return step == 1 || agentIsReady
    }

    /// The segmented picker sets its binding even for a click on the selected segment, and the
    /// sheet's reload only re-fires when the agent actually changes.
    public func selectAgent(_ id: String) {
        guard id != draft.agentId else { return }
        draft.agentId = id
        // The old agent's list goes now, not when the new one has loaded.
        completions.all = []
        completions.close()
        models = []
        catalogueLoaded = false
        catalogueFailure = nil
        resetModel = true
    }

    public func setModel(_ id: String) {
        draft.setModel(id, catalog: models, efforts: agent.reasoningLevels, defaultEffort: agent.defaultReasoning)
    }

    /// The draft's agent's models, read off the main actor. An answer for an agent no longer
    /// picked, or from an older read, is dropped.
    public func loadCatalogue() async {
        catalogueGeneration += 1
        let generation = catalogueGeneration, agent = self.agent, remembered = rememberedModels[agent.id], read = catalogue
        let home = self.home, path = project.path
        let result = await BackgroundWork.run { () -> (models: [AgentModel], failure: String?, completions: [AgentCompletion]) in
            let skills = SkillCatalog.discover(agentId: agent.id, projectPath: path, home: home)
            do { return (try read(agent), nil, skills) } catch { return ([], error.localizedDescription, skills) }
        }
        guard !Task.isCancelled, generation == catalogueGeneration, agent.id == draft.agentId else { return }
        models = result.models
        catalogueFailure = result.failure
        catalogueLoaded = true
        completions.all = result.completions
        completions.close()
        if resetModel || !models.contains(where: { $0.id == draft.model }) {
            let preference = ModelPreference.resolve(catalog: models, remembered: remembered)
            draft.model = preference.model
            draft.reasoning = preference.reasoning
            resetModel = false
        }
    }

    public func loadBranches() async {
        let list = listBranches
        let found = await BackgroundWork.run { list() }
        guard !Task.isCancelled else { return }
        branches = found
        kind.branchesLoaded(found, into: &draft, opened: opened)
    }

    /// False means nothing was created and the same draft can be corrected — notably when git
    /// refuses the branch.
    /// A cancelled create also returns false, with `cancelled` set and no error.
    public func create() async -> Bool {
        guard !creating, agentIsReady else { return false }
        let cancellation = CreationCancellation()
        creating = true; error = nil; progress = nil; cancelling = false; cancelled = false
        self.cancellation = cancellation
        defer { creating = false; progress = nil; cancelling = false; self.cancellation = nil }
        // The work runs off the main actor; its steps come back to it, and only while it runs.
        let report: @Sendable (CreationStep) -> Void = { step in
            Task { @MainActor [weak self] in if self?.creating == true { self?.progress = step } }
        }
        do {
            try await CreationContext.$cancellation.withValue(cancellation) {
                try await CreationContext.$report.withValue(report) { try await submit(draft) }
            }
            return true
        } catch is CreationCancelled {
            cancelled = true
        } catch {
            self.error = CreationFailure(error)
        }
        return false
    }

    /// Stops the running create: the work ends what it runs and undoes what it made.
    public func cancelCreate() {
        guard creating, !cancelling else { return }
        cancelling = true
        cancellation?.cancel()
    }

    // -- the search field (AiTerm's CreationModel search) --------------------------------------

    public func cancelSearch() {
        searchGeneration += 1
        searchTask?.cancel()
        searchTask = nil
    }

    /// The field's text as it is typed: kept, and searched for after a pause.
    public func setQuery(_ text: String) {
        query = text
        cancelSearch()
        searchTask = Task { await search(text: text, debounce: true) }
    }

    /// Back to the default list, as clearing a pick does: an empty query, searched at once.
    public func reopenSearch() { setQuery("") }

    /// An answer that arrives after a newer search, or after the search was abandoned, is dropped.
    /// A failure clears the list: rows from an earlier query beside an error about this one would
    /// read as its answer.
    public func search(text: String, debounce: Bool = false) async {
        searchGeneration += 1
        let generation = searchGeneration
        do {
            if debounce { try await Task.sleep(for: .milliseconds(250)) }
            try Task.checkCancellation()
            let found = try await searchItems(text)
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = found; searchError = nil
        } catch {
            guard !Task.isCancelled, generation == searchGeneration else { return }
            results = []
            searchError = error.localizedDescription
        }
    }

    /// Names the missing CLIs and where Settings installs them; nothing when every one is there.
    public static func missingAgentNote(agents: [AgentDefinition], available: Set<String>) -> String? {
        let missing = agents.filter { !available.contains($0.id) }.map(\.name)
        guard let last = missing.last else { return nil }
        let names = missing.count == 1 ? last : missing.dropLast().joined(separator: ", ") + " and " + last
        return names + (missing.count == 1 ? " isn’t installed. Install it" : " aren’t installed. Install them")
            + " in Settings › Agents."
    }
}

extension CreationModel where Kind == TaskCreation {
    /// New Task's model, its search being Jira's.
    public convenience init(project: Project, agents: [AgentDefinition], available: Set<String>, draft: TaskDraft,
                            rememberedModels: [String: String],
                            catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel],
                            branches: @escaping @Sendable () -> [String],
                            submit: @escaping @MainActor (TaskDraft) async throws -> Void,
                            searchIssues: @escaping @MainActor (String) async throws -> [JiraTicket] = { _ in [] },
                            sshHost: String? = nil,
                            existingWorktrees: @escaping @Sendable () -> [ExistingWorktree] = { [] }, home: URL) {
        self.init(kind: TaskCreation(sshHost: sshHost, listExisting: existingWorktrees), project: project, agents: agents, available: available, draft: draft, rememberedModels: rememberedModels,
                  catalogue: catalogue, branches: branches, submit: submit, search: searchIssues, home: home)
    }

    /// New worktree or Existing worktree: the first listed is picked when none is.
    public func chooseExisting(_ on: Bool) {
        guard on else { draft.leaveExisting(); return }
        draft.useExisting = true
        if let picked = draft.existing { draft.pick(existing: picked) } else if let first = kind.existing.first { draft.pick(existing: first) }
    }

    /// The worktrees "Existing worktree" lists, read off the main actor. A pick that is no longer
    /// among them goes.
    public func loadExistingWorktrees() async {
        let list = kind.listExisting
        let found = await BackgroundWork.run { list() }
        guard !Task.isCancelled else { return }
        objectWillChange.send()
        kind.existing = found
        if let picked = draft.existing, !found.contains(picked) { draft.pick(existing: nil) }
        if draft.useExisting, draft.existing == nil, let first = found.first { draft.pick(existing: first) }
    }

    /// The ticket list's open flag, as New Task names it.
    public var ticketsOpen: Bool {
        get { listOpen }
        set { listOpen = newValue }
    }

    /// The ticket field's placeholder names what it searches: the linked Jira projects, or — with
    /// none linked — every project the account can see.
    public var ticketPlaceholder: String {
        project.jiraProjects.isEmpty ? "Search by key or title" : "Search \(project.jiraProjects.keyList) by key or title"
    }

    /// AiTerm's `jiraSearcher`: an empty query lists the person's open tickets, across every linked
    /// Jira project; anything else searches for it there. `jira` is the connection as it stood when
    /// the sheet opened — reading it is a Keychain call, too slow for every keystroke. `session` is
    /// the tests' way to see the queries.
    public static func jiraSearcher(for project: Project, jira: JiraConfig?,
                                    session: URLSession = .shared) -> @MainActor (String) async throws -> [JiraTicket] {
        let jiraProjects = project.jiraProjects
        return { text in
            guard let config = jira else {
                throw ActionUnavailable("Connect Jira in Settings, or continue without a ticket.")
            }
            let client = JiraClient(config: config, session: session)
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? try await client.myOpenIssues(projects: jiraProjects)
                : try await client.search(text: text, projects: jiraProjects)
        }
    }
}
