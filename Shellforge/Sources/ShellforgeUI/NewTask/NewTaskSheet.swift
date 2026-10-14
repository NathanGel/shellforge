// Ported from AiTerm (app/Sources/AiTerm/Views/NewTaskSheet.swift and CreationSheet.swift), GPLv3, Laurens D'Hondt.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// AiTerm's New Task sheet: Task, Agent and Prompt, the step bar, the command preview under every
/// step past the first, the destination line that ends steps 1 and 3, and the footer. Its Jira
/// ticket field searches every Jira project the account can see until projects are linked (M1d-2).
struct NewTaskSheet: View {
    @ObservedObject var model: NewTaskModel
    let dismiss: @MainActor () -> Void
    @State private var step = 1
    /// A result row's key column: a Jira key of up to eight characters in the mono code face, so
    /// the summaries after it start on one line.
    private static let ticketKeyWidth: CGFloat = 74

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
        // A click past the ticket list closes it, as AiTerm's CreationSheet closes its pickers.
        SheetLayout(title: "New task in \(model.project.name)", height: Sheet.height,
                    onBackgroundTap: { model.ticketsOpen = false }) {
            StepBar(step: step, names: ["Task", "Agent", "Prompt"])
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                Group {
                    switch step {
                    case 1: taskStep
                    case 2: AgentStep(model: model)
                    default:
                        VStack(alignment: .leading, spacing: Space.block) {
                            PromptStep(text: $model.draft.promptText, agentId: model.draft.agentId, completions: model.completions)
                                .zIndex(1)
                            if model.draft.ticket != nil {
                                Toggle("Include Jira ticket details", isOn: $model.draft.appendTicket)
                                    .toggleStyle(.checkbox).font(Typography.body)
                            }
                            if let host = model.draft.paneHost {
                                Toggle("Open ssh \(host) beside the agent", isOn: $model.draft.openSSH)
                                    .toggleStyle(.checkbox).font(Typography.body)
                            }
                        }
                    }
                }
                // The prompt's popup hangs over the command preview: AiTerm's FrontToBackStack.
                .zIndex(1)
                if step > 1 { CommandBlock(caption: "Command", command: model.previewCommand) }
                if Destination.isShown(onStep: step), let destination { DestinationLine(destination) }
            }
        } footer: {
            CreationFooter(step: step, error: model.error,
                           missingAgentNote: Self.footerNote(agents: model.agents, available: model.availableAgents),
                           createLabel: "Create Task", creating: model.creating,
                           canAdvance: model.canAdvance(step: step),
                           closeList: {
                               if step == 1, model.ticketsOpen { model.ticketsOpen = false; return true }
                               return Self.closeList(step: step, completions: model.completions)
                           },
                           back: back, advance: advance)
        }
        .task { await model.search(text: "") }
        .onDisappear { model.cancelSearch() }
        .task { await model.loadBranches() }
        .task { await model.loadExistingWorktrees() }
        .task(id: model.draft.agentId) { await model.loadCatalogue() }
    }

    /// As AiTerm's footer: why Create is dead, said only when no agent can run at all; the Agent
    /// step names the missing ones either way.
    static func footerNote(agents: [AgentDefinition], available: Set<String>) -> String? {
        available.isEmpty ? NewTaskModel.missingAgentNote(agents: agents, available: available) : nil
    }

    // -- step 1: task ---------------------------------------------------------------

    private var taskStep: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            // A new worktree, or one that already exists to continue in.
            SegmentedControl(values: [false, true], selection: Binding(get: { model.draft.useExisting }, set: { model.chooseExisting($0) })) { existing, on in
                Text(existing ? "Existing worktree" : "New worktree").font(on ? Typography.bodyEmphasis : Typography.body)
            }
            FormField("Jira ticket (optional)") {
                SearchPicker(placeholder: model.ticketPlaceholder,
                             query: Binding(get: { model.query }, set: { model.setQuery($0) }),
                             open: $model.ticketsOpen,
                             items: model.results, selection: model.draft.ticket,
                             row: { ticket in
                                 // The lane column stays for a ticket without one, so every summary
                                 // is cut at the same place.
                                 PickerResultRow(mark: .brand(Palette.jira), key: ticket.key, keyWidth: Self.ticketKeyWidth,
                                                 title: ticket.summary, detail: ticket.status ?? "")
                             },
                             selected: { selectedTicket($0) },
                             onPick: { ticket in
                                 model.cancelSearch()
                                 model.draft.apply(ticket: ticket)
                             },
                             toggleHelp: { $0 ? "Hide tickets" : "Show my open tickets" })
                // Over the help text after it, as AiTerm's FormField orders its content front to back.
                .zIndex(1)
                if model.draft.ticket == nil {
                    if let message = model.searchError {
                        HelpText(message, tone: .warning)
                    } else {
                        HelpText("Select a ticket to fill in the name, type and branch.")
                    }
                }
            }
            // The ticket list hangs over the fields below it: AiTerm's FrontToBackStack.
            .zIndex(1)

            FormField("Task name") {
                Input(placeholder: "Describe the task", text: Binding(get: { model.draft.title }, set: { model.draft.setTitle($0) }))
            }

            if model.draft.useExisting {
                existingWorktreeField
            } else {
                branchFields
            }
        }
    }

    /// The worktree to continue in, newest first; its branch is the task's, as it is.
    @ViewBuilder private var existingWorktreeField: some View {
        FormField("Worktree") {
            if model.kind.existing.isEmpty {
                HelpText("\(model.project.name) has no other worktrees to continue in.")
            } else {
                Select(values: model.kind.existing,
                       selection: Binding(get: { model.draft.existing ?? model.kind.existing[0] }, set: { model.draft.pick(existing: $0) }),
                       label: { $0.branch }, detail: { ExistingWorktreeLabel.detail(of: $0, in: model.project) }, monospaced: true)
                HelpText("Continues on its branch as it is: nothing in git changes.")
            }
        }
    }

    private var branchFields: some View {
        VStack(alignment: .leading, spacing: Space.block) {
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

    private func selectedTicket(_ ticket: JiraTicket) -> some View {
        PickedItemField(mark: .brand(Palette.jira), key: ticket.key, title: ticket.summary, trailing: {
            if let status = ticket.status { LaneChip(lane: status, brand: Palette.jira, ink: Palette.link) }
        }, clearHelp: "Clear ticket") {
            model.draft.apply(ticket: nil); model.reopenSearch(); model.ticketsOpen = true
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
        if model.draft.useExisting { return model.draft.existing.map { .existing(project: model.project, worktree: $0) } }
        let slug = model.worktreeSlug
        guard !slug.isEmpty else { return nil }
        return .worktree(project: model.project, slug: slug, branch: model.draft.branchName.isEmpty ? "" : model.draft.branch)
    }

    // -- moving between steps -------------------------------------------------------

    /// ⎋ belongs to an open popup first, as AiTerm's `closeOpenList`: only the prompt step has one.
    static func closeList(step: Int, completions: PromptCompletions) -> Bool {
        guard step == 3, completions.isOpen else { return false }
        completions.close()
        return true
    }

    /// Leaving `step`: the prompt step's popup goes with it.
    static func leave(step: Int, completions: PromptCompletions) {
        if step == 3 { completions.close() }
    }

    /// Leaving `step`, every list hanging in it closes.
    static func leave(step: Int, model: NewTaskModel) {
        if step == 1 { model.ticketsOpen = false }
        leave(step: step, completions: model.completions)
    }

    enum BackMove: Equatable { case step(Int), dismiss, stay }

    /// ⎋ and Back are one move: a step back, or the sheet closed from the first step — never while
    /// a create runs.
    static func back(from step: Int, creating: Bool) -> BackMove {
        guard !creating else { return .stay }
        return step == 1 ? .dismiss : .step(step - 1)
    }

    private func back() {
        switch Self.back(from: step, creating: model.creating) {
        case .step(let previous): Self.leave(step: step, model: model); step = previous
        // A turn later, as AiTerm's `afterThisEvent`: the panel is not closed under the event.
        case .dismiss: Task { @MainActor in dismiss() }
        case .stay: break
        }
    }

    /// What the primary button does, named once: the button and ⌘↩ both call it, and
    /// `canAdvance` gates both.
    private func advance() {
        if step == 3 { create(); return }
        Self.leave(step: step, model: model)
        step += 1
    }

    /// Already past the button's event by the time it dismisses: the create is awaited first.
    private func create() { Task { @MainActor in if await model.create() { dismiss() } } }
}

#if DEBUG
extension NewTaskSheet {
    /// The sheet already on `step`: what only clicks reach in the app, for the tests that host it.
    func seeded(step: Int) -> Self {
        var sheet = self
        sheet._step = State(initialValue: step)
        return sheet
    }
}
#endif
