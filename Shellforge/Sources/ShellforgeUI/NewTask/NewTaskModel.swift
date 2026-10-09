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

/// The New Task sheet's state: the draft, the chosen agent's models, the project's branches, and
/// the one create call. AiTerm's `CreationModel<TaskCreation>` on an `ObservableObject` (macOS 13
/// has no `@Observable`), without its Jira search (M1d) and prompt completions (M1c-3d).
@MainActor
public final class NewTaskModel: ObservableObject, Identifiable {
    public nonisolated let id = UUID()
    public let project: Project
    public let agents: [AgentDefinition]
    @Published public var draft: TaskDraft
    @Published public private(set) var branches: [String] = []
    @Published public private(set) var models: [AgentModel] = []
    @Published public private(set) var catalogueLoaded = false
    /// Why the chosen agent has no models to offer, when its list could not be read.
    @Published public private(set) var catalogueFailure: String?
    @Published public private(set) var creating = false
    @Published public private(set) var error: CreationFailure?
    /// The agents whose CLIs the login shell finds, read when the sheet opens.
    public let availableAgents: Set<String>

    private let rememberedModels: [String: String]
    private let catalogue: @Sendable (AgentDefinition) throws -> [AgentModel]
    private let listBranches: @Sendable () -> [String]
    private let submit: @MainActor (TaskDraft) async throws -> Void
    private var catalogueGeneration = 0
    private var resetModel = false
    /// The base branch the draft opened with: replaced by the repository's default once the
    /// branches are read, unless the person picked another meanwhile.
    private let openedBase: String
    /// `worktreeSlug` stats the worktree directory; remembered per slug so a redraw does not.
    private var unusedSlugMemo: (slug: String, unused: String)?

    public init(project: Project, agents: [AgentDefinition], available: Set<String>, draft: TaskDraft,
                rememberedModels: [String: String],
                catalogue: @escaping @Sendable (AgentDefinition) throws -> [AgentModel],
                branches: @escaping @Sendable () -> [String],
                submit: @escaping @MainActor (TaskDraft) async throws -> Void) {
        self.project = project
        self.agents = agents
        self.availableAgents = available
        self.draft = draft
        self.openedBase = draft.baseBranch
        self.rememberedModels = rememberedModels
        self.catalogue = catalogue
        self.listBranches = branches
        self.submit = submit
    }

    /// The draft's agent; the first one when the draft names none the sheet knows.
    public var agent: AgentDefinition { agents.first { $0.id == draft.agentId } ?? agents[0] }

    /// The worktree directory the sheet names: the one create will make.
    public var worktreeSlug: String {
        let slug = draft.worktreeSlug
        guard !slug.isEmpty else { return "" }
        if let memo = unusedSlugMemo, memo.slug == slug { return memo.unused }
        let unused = BranchNaming.unused(slug, in: project.path)
        unusedSlugMemo = (slug, unused)
        return unused
    }

    /// The exact command the task will run, built without touching the disk.
    public var previewCommand: String {
        AgentCommand.previewCommand(agent: agent, model: draft.model, reasoning: draft.reasoning,
                                    prompt: AgentCommand.composePrompt(userText: draft.promptText))
    }

    public var selectedModelIsCurrent: Bool { catalogueLoaded && models.contains { $0.id == draft.model } }

    /// Whether the draft's agent can run: its CLI is installed and its model is one the catalogue
    /// still offers.
    public var agentIsReady: Bool { availableAgents.contains(draft.agentId) && selectedModelIsCurrent }

    /// Step 1 needs a name and nothing else; the agent and prompt steps need an agent that can run.
    public func canAdvance(step: Int) -> Bool {
        guard !creating, !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return step == 1 || agentIsReady
    }

    /// The segmented picker sets its binding even for a click on the selected segment, and the
    /// sheet's reload only re-fires when the agent actually changes.
    public func selectAgent(_ id: String) {
        guard id != draft.agentId else { return }
        draft.agentId = id
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
        let result = await BackgroundWork.run { () -> (models: [AgentModel], failure: String?) in
            do { return (try read(agent), nil) } catch { return ([], error.localizedDescription) }
        }
        guard !Task.isCancelled, generation == catalogueGeneration, agent.id == draft.agentId else { return }
        models = result.models
        catalogueFailure = result.failure
        catalogueLoaded = true
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
        if draft.baseBranch == openedBase, let first = found.first { draft.baseBranch = first }
    }

    /// False means nothing was created and the same draft can be corrected — notably when git
    /// refuses the branch.
    public func create() async -> Bool {
        guard !creating, agentIsReady else { return false }
        creating = true; error = nil
        defer { creating = false }
        do { try await submit(draft); return true }
        catch { self.error = CreationFailure(error) }
        return false
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
