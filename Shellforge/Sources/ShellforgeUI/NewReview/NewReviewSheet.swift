// Ported from AiTerm (app/Sources/AiTerm/Views/NewReviewSheet.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// New Review's three steps: Branch, Agent, Prompt. A review checks out a branch that already
/// exists — optionally the source branch of a merge request — instead of creating one, so step 1
/// picks rather than derives, and there is no base branch to choose.
struct NewReviewSheet: View {
    @ObservedObject var model: ReviewCreationModel
    let dismiss: @MainActor () -> Void
    @State private var step = 1

    /// A result row's `!iid` column: a four-digit number in the mono code face, so the titles after
    /// it start on one line.
    private static let mrNumberWidth: CGFloat = 44

    init(model: ReviewCreationModel, dismiss: @escaping @MainActor () -> Void) {
        self.model = model
        self.dismiss = dismiss
    }

    var body: some View {
        // A click past the lists closes them, as AiTerm's CreationSheet closes its pickers.
        SheetLayout(title: "New review in \(model.project.name)", height: Sheet.height,
                    onBackgroundTap: { Self.closeLists(model) }) {
            StepBar(step: step, names: ["Branch", "Agent", "Prompt"])
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                Group {
                    switch step {
                    case 1: branchStep
                    case 2: AgentStep(model: model)
                    default: PromptStep(text: $model.draft.promptText, agentId: model.draft.agentId, completions: model.completions)
                    }
                }
                // The lists and the prompt's popup hang over the command preview and the destination.
                .zIndex(1)
                if step > 1 { CommandBlock(caption: "Command", command: model.previewCommand) }
                if let destination = Self.destination(step: step, project: model.project, slug: model.worktreeSlug,
                                                      branch: model.draft.branch) {
                    DestinationLine(destination)
                }
            }
        } footer: {
            CreationFooter(step: step, error: model.error,
                           missingAgentNote: NewTaskSheet.footerNote(agents: model.agents, available: model.availableAgents),
                           createLabel: "Create Review", creating: model.creating,
                           canAdvance: Self.canAdvance(step: step, model: model),
                           closeList: { Self.closeList(step: step, model: model) },
                           back: back, advance: advance)
        }
        .task { await model.search(text: "") }
        .onDisappear { model.cancelSearch() }
        .task { await model.loadBranches() }
        .task(id: model.draft.agentId) { await model.loadCatalogue() }
    }

    // -- step 1: branch -------------------------------------------------------------

    private var branchStep: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            FormField(model.codeHost.reviewField) {
                SearchPicker(placeholder: model.codeHost.reviewPlaceholder,
                             query: Binding(get: { model.query }, set: { model.setQuery($0) }),
                             open: $model.listOpen,
                             items: model.results, selection: model.draft.mr,
                             row: mrRow, selected: selectedMR,
                             onPick: { mr in model.pick(mr) },
                             toggleHelp: { $0 ? "Hide \(model.codeHost.reviewNoun)s" : "Show open \(model.codeHost.reviewNoun)s" })
                    // Over the help line after it, as AiTerm's FormField orders its content front to back.
                    .zIndex(1)
                if let message = model.pickRefusal ?? model.searchError {
                    HelpText(message, tone: .warning)
                } else if model.draft.mr == nil {
                    // An instruction to pick one reads wrong under one already picked.
                    HelpText(model.codeHost.reviewHint)
                }
            }
            // The request list hangs over the name and branch fields below it.
            .zIndex(2)

            FormField("Review name") {
                Input(placeholder: "Describe the review", text: Binding(get: { model.draft.title }, set: { model.draft.setTitle($0) }))
            }

            FormField("Branch") {
                SearchPicker(placeholder: "Search branches",
                             query: Binding(get: { model.branchQuery }, set: { model.branchQuery = $0 }),
                             open: Binding(get: { model.branchListOpen }, set: { model.branchListOpen = $0 }),
                             items: model.branchMatches.map(BranchChoice.init),
                             selection: model.draft.branch.isEmpty ? nil : BranchChoice(model.draft.branch),
                             row: { BranchResultRow(name: $0.name) },
                             selected: selectedBranch,
                             onPick: { choice in model.draft.setBranch(choice.name) },
                             toggleHelp: { $0 ? "Hide branches" : "Show all branches" })
            }
            .zIndex(1)
        }
    }

    /// `SearchPicker` keys on `Identifiable`; a branch is a bare `String`, so it travels wrapped.
    private struct BranchChoice: Identifiable, Equatable {
        let name: String
        var id: String { name }
        init(_ name: String) { self.name = name }
    }

    /// A branch in the results, in the ink of the ground its row declares — white while highlighted.
    private struct BranchResultRow: View {
        let name: String
        @Environment(\.surface) private var surface

        var body: some View {
            Text(name).font(Typography.monoCode).foregroundStyle(surface.ink).lineLimit(1)
        }
    }

    private func mrRow(_ mr: MergeRequest) -> some View {
        PickerResultRow(mark: .brand(mr.host.brand), key: mr.reference, keyWidth: Self.mrNumberWidth,
                        title: mr.title, detail: mr.lane)
    }

    private func selectedMR(_ mr: MergeRequest) -> some View {
        PickedItemField(mark: .brand(mr.host.brand), key: mr.reference, title: mr.title, trailing: {
            LaneChip(lane: mr.lane, brand: mr.host.brand, ink: mr.host.brand.color)
        }, clearHelp: "Clear \(model.codeHost.reviewNoun)") {
            model.clearPick(); model.reopenSearch(); model.listOpen = true
        }
    }

    private func selectedBranch(_ choice: BranchChoice) -> some View {
        PickedItemField(title: choice.name, monospaced: true, clearHelp: "Change branch") {
            model.draft.setBranch(""); model.branchQuery = ""; model.branchListOpen = true
        }
    }

    // -- the rules ------------------------------------------------------------------------

    /// Step 1 needs both a name and a branch: a review derives neither — there is nothing to fall
    /// back on if the branch is blank, unlike a task whose branch follows its title.
    static func canAdvance(step: Int, title: String, branch: String, creating: Bool) -> Bool {
        guard !creating else { return false }
        let named = !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard step == 1 else { return named }
        return named && !branch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The rule above, and past step 1 an agent that can run.
    static func canAdvance(step: Int, model: ReviewCreationModel) -> Bool {
        guard canAdvance(step: step, title: model.draft.title, branch: model.draft.branch, creating: model.creating) else { return false }
        return step == 1 || model.agentIsReady
    }

    /// Where the review opens, on steps 1 and 3, once it has a branch: a worktree of its own.
    /// `slug` is read only when the line is drawn — finding the unused slug looks at the disk.
    static func destination(step: Int, project: Project, slug: @autoclosure () -> String, branch: String) -> Destination? {
        guard Destination.isShown(onStep: step), !branch.isEmpty else { return nil }
        return .worktree(project: project, slug: slug(), branch: branch)
    }

    /// ⎋ belongs to an open list first: the request list, then the branch list, on step 1; the
    /// prompt's popup on step 3.
    static func closeList(step: Int, model: ReviewCreationModel) -> Bool {
        if step == 1, model.listOpen { model.listOpen = false; return true }
        if step == 1, model.branchListOpen { model.branchListOpen = false; return true }
        return NewTaskSheet.closeList(step: step, completions: model.completions)
    }

    static func closeLists(_ model: ReviewCreationModel) {
        model.listOpen = false
        model.branchListOpen = false
    }

    /// Leaving `step`, every list hanging in it closes.
    static func leave(step: Int, model: ReviewCreationModel) {
        if step == 1 { closeLists(model) }
        NewTaskSheet.leave(step: step, completions: model.completions)
    }

    private func back() {
        switch NewTaskSheet.back(from: step, creating: model.creating) {
        case .step(let previous): Self.leave(step: step, model: model); step = previous
        // A turn later: the panel is not closed under the event.
        case .dismiss: Task { @MainActor in dismiss() }
        case .stay: break
        }
    }

    private func advance() {
        if step == 3 { create(); return }
        Self.leave(step: step, model: model)
        step += 1
    }

    private func create() { Task { @MainActor in if await model.create() { dismiss() } } }
}

#if DEBUG
extension NewReviewSheet {
    /// The sheet already on `step`: what only clicks reach in the app, for the tests that host it.
    func seeded(step: Int) -> Self {
        var sheet = self
        sheet._step = State(initialValue: step)
        return sheet
    }
}
#endif
