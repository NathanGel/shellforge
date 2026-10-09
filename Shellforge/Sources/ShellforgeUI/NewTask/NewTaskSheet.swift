// Ported from AiTerm (app/Sources/AiTerm/Views/NewTaskSheet.swift and CreationSheet.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// AiTerm's New Task sheet: Task, Agent and Prompt, the step bar, the command preview under every
/// step past the first, the destination line that ends steps 1 and 3, and the footer. Its Jira
/// ticket field (M1d) and the prompt's completions (M1c-3d) are not here yet.
struct NewTaskSheet: View {
    @ObservedObject var model: NewTaskModel
    let dismiss: @MainActor () -> Void
    @State private var step = 1

    /// The branch-type popup's column: its longest type, `chore`, in monospace plus the popup's
    /// chevron and bezel — no wider, since every point it takes comes out of the branch name
    /// beside it.
    private static let branchTypeWidth: CGFloat = 96
    /// The base-branch popup's column: room for `main`, `develop` or a short release branch in
    /// monospace, the rest of the row left to the new branch's name.
    private static let baseBranchWidth: CGFloat = 190

    init(model: NewTaskModel, dismiss: @escaping @MainActor () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    var body: some View {
        SheetLayout(title: "New task in \(model.project.name)", height: Sheet.height) {
            StepBar(step: step, names: ["Task", "Agent", "Prompt"])
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                switch step {
                case 1: taskStep
                case 2: AgentStep(model: model)
                default: PromptStep(text: $model.draft.promptText)
                }
                if step > 1 { CommandBlock(caption: "Command", command: model.previewCommand) }
                if Destination.isShown(onStep: step), let destination { DestinationLine(destination) }
            }
        } footer: {
            CreationFooter(step: step, error: model.error,
                           missingAgentNote: NewTaskModel.missingAgentNote(agents: model.agents, available: model.availableAgents),
                           createLabel: "Create Task", creating: model.creating,
                           canAdvance: model.canAdvance(step: step), closeList: { false },
                           back: back, advance: advance)
        }
        .task { await model.loadBranches() }
        .task(id: model.draft.agentId) { await model.loadCatalogue() }
    }

    // -- step 1: task ---------------------------------------------------------------

    private var taskStep: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            FormField("Task name") {
                Input(placeholder: "Describe the task", text: Binding(get: { model.draft.title }, set: { model.draft.setTitle($0) }))
            }

            HStack(alignment: .top, spacing: Space.gap) {
                FormField("Type") {
                    Select(values: BranchType.allCases, selection: Binding(get: { model.draft.branchType }, set: { model.draft.setBranchType($0) }),
                           label: { $0.rawValue }, detail: { $0.summary }, monospaced: true)
                }.frame(width: Self.branchTypeWidth)
                FormField("New branch") {
                    Input(placeholder: "branch-name", text: Binding(get: { model.draft.branchName }, set: { model.draft.setBranch($0) }), monospaced: true)
                }
                FormField("Base branch") {
                    Select(values: baseBranchChoices, selection: $model.draft.baseBranch, label: { $0 }, monospaced: true)
                }.frame(width: Self.baseBranchWidth)
            }
        }
    }

    /// The popup always offers the branch the draft is on, even if git has not heard of it yet —
    /// an `NSPopUpButton` whose selection is not in its menu shows nothing at all.
    private var baseBranchChoices: [String] {
        model.branches.contains(model.draft.baseBranch) || model.draft.baseBranch.isEmpty ? model.branches : [model.draft.baseBranch] + model.branches
    }

    /// Where the task opens: its new worktree, on steps 1 and 3 only — finding the unused slug
    /// looks at the disk. Nothing until the task has a name to make a worktree of.
    private var destination: Destination? {
        guard Destination.isShown(onStep: step) else { return nil }
        let slug = model.worktreeSlug
        guard !slug.isEmpty else { return nil }
        return .worktree(project: model.project, slug: slug, branch: model.draft.branchName.isEmpty ? "" : model.draft.branch)
    }

    // -- moving between steps -------------------------------------------------------

    enum BackMove: Equatable { case step(Int), dismiss, stay }

    /// ⎋ and Back are one move: a step back, or the sheet closed from the first step — never while
    /// a create runs.
    static func back(from step: Int, creating: Bool) -> BackMove {
        guard !creating else { return .stay }
        return step == 1 ? .dismiss : .step(step - 1)
    }

    private func back() {
        switch Self.back(from: step, creating: model.creating) {
        case .step(let previous): step = previous
        // A turn later, as AiTerm's `afterThisEvent`: the panel is not closed under the event.
        case .dismiss: Task { @MainActor in dismiss() }
        case .stay: break
        }
    }

    /// What the primary button does, named once: the button and ⌘↩ both call it, and
    /// `canAdvance` gates both.
    private func advance() {
        if step == 3 { create(); return }
        step += 1
    }

    /// Already past the button's event by the time it dismisses: the create is awaited first.
    private func create() { Task { @MainActor in if await model.create() { dismiss() } } }
}
