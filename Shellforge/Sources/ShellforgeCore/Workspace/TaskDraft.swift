// Ported from AiTerm (app/Sources/AiTermCore/Tasks/TaskCreator.swift and Tasks/AgentDraft.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Where the task's agent works: a new worktree, one that exists, or the project's own folder.
public enum WorktreeChoice: Equatable, Sendable { case new, existing, projectFolder }

/// What the New Task sheet is filling in: the task's name and branch, the branch it starts from,
/// and the agent its first tab runs, with which model, reasoning level and first prompt. AiTerm's
/// `TaskDraft`, its Jira ticket included.
public struct TaskDraft: Equatable, Sendable {
    /// The branch is kept as its two halves — the type the select shows and the name the field
    /// shows — so each can be changed without the other.
    public var ticket: JiraTicket?
    public private(set) var title = "", branchType = BranchType.feat, branchName = ""
    public var baseBranch: String, agentId: String, model: String, reasoning: String?
    public var promptText = "", appendTicket = true
    /// Open the project's SSH host in a pane beside the agent, when it has one.
    public var openSSH = true
    /// The host New Task offered as that pane when it opened; nil when it offered none, so the box
    /// was never shown.
    public var paneHost: String?
    /// Where the task works; see `choose(_:)`.
    public private(set) var worktree = WorktreeChoice.new
    /// Continue in a worktree that already exists rather than make one (ExistingWorktrees).
    public var useExisting: Bool { worktree == .existing }
    /// The worktree picked to continue in, while `useExisting`.
    public private(set) var existing: ExistingWorktree?
    /// The branch a Project folder task switches the folder to first; nil keeps the one checked out.
    public var folderBranch: String?
    private var titleEdited = false, branchEdited = false, typeEdited = false
    /// The branch was typed whole, with no type, where the field held the whole branch: a Ticket Key
    /// Only project's `ABC-123-v2`.
    private var typedWhole = false

    /// How the project names its branches, set when the sheet opens for it.
    public var branchFormat = BranchFormat.typeAndName

    /// Whether the branch is the ticket's key alone: the project asks for it, a ticket is picked, and
    /// the branch was not typed by hand.
    public var usesTicketKey: Bool { branchFormat == .ticketKey && ticket != nil && !branchEdited }

    /// Whether the branch field holds the whole branch, with no type to choose beside it: the
    /// ticket's key, or a branch typed in its place.
    public var namesWholeBranch: Bool { usesTicketKey || typedWhole }

    public var branch: String {
        if usesTicketKey { return ticket?.key ?? "" }
        return typedWhole ? branchName : typeAndNameBranch
    }

    /// What the branch field shows: the key while the branch is that, else the name half.
    public var branchFieldText: String { usesTicketKey ? ticket?.key ?? "" : branchName }

    private var typeAndNameBranch: String { "\(branchType.rawValue)/\(branchName)" }

    /// The branch's worktree directory before a taken one is skipped (`BranchNaming.unused`, which
    /// the sheet applies): nothing while the name field is empty, rather than the type alone that
    /// `BranchNaming.worktreeSlug` falls back to for a bare `feat/`.
    public var worktreeSlug: String {
        branchName.trimmingCharacters(in: .whitespaces).isEmpty ? "" : BranchNaming.worktreeSlug(branch: typeAndNameBranch)
    }

    public init(baseBranch: String, agentId: String, model: String, reasoning: String?) {
        self.baseBranch = baseBranch; self.agentId = agentId; self.model = model; self.reasoning = reasoning
    }

    /// Both guard against being handed what they already hold: SwiftUI writes a `TextField`'s value
    /// back through its binding when editing begins and ends, not only when the text changes, so a
    /// click into another field would otherwise mark the branch hand-edited and stop it following
    /// the task name.
    public mutating func setTitle(_ t: String) {
        guard t != title else { return }
        title = t; titleEdited = true
        if !branchEdited { branchName = BranchNaming.branchSlug(key: ticket?.key, summary: t) }
    }

    /// Clearing the ticket keeps the type it chose: nothing else has a better idea of the work.
    public mutating func apply(ticket: JiraTicket?) {
        self.ticket = ticket
        if !titleEdited { title = ticket?.summary ?? title }
        if !typeEdited, let ticket { branchType = BranchType(issueType: ticket.issueType) }
        if !branchEdited { branchName = BranchNaming.branchSlug(key: ticket?.key, summary: ticket?.summary ?? title) }
    }

    /// The branch field's text: a name, or a whole branch whose known type prefix moves into the
    /// select — typing `fix/` is picking the type. Where the field holds the whole branch (a Ticket
    /// Key Only project's key), a branch with no known type prefix is the whole branch as typed.
    public mutating func setBranch(_ b: String) {
        if usesTicketKey && b == ticket?.key { return }
        let split = BranchType.split(b)
        if let split { branchType = split.type; typeEdited = true }
        let whole = split == nil && namesWholeBranch
        let name = split?.name ?? b
        guard name != branchName || whole != typedWhole else { return }
        branchName = name; branchEdited = true; typedWhole = whole
    }

    /// The worktree to continue in: the task takes its branch's name, unless one was typed.
    public mutating func pick(existing worktree: ExistingWorktree?) {
        existing = worktree
        if !titleEdited, let worktree { title = worktree.branch }
    }

    /// Where the task works. Leaving Existing worktree: a name the picked worktree gave goes, the
    /// ticket's (or none) back.
    public mutating func choose(_ choice: WorktreeChoice) {
        let leaving = worktree == .existing && choice != .existing
        worktree = choice
        if leaving { clearPickedName() }
    }

    private mutating func clearPickedName() {
        guard !titleEdited else { return }
        title = ticket?.summary ?? ""
        if !branchEdited { branchName = BranchNaming.branchSlug(key: ticket?.key, summary: ticket?.summary ?? title) }
    }

    public mutating func setBranchType(_ type: BranchType) {
        guard type != branchType else { return }
        branchType = type; typeEdited = true
    }
}
