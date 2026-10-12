// Ported from AiTerm (app/Sources/AiTermCore/Tasks/TaskCreator.swift and Tasks/AgentDraft.swift), GPLv3, Laurens D'Hondt.
import Foundation

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
    private var titleEdited = false, branchEdited = false, typeEdited = false

    public var branch: String { "\(branchType.rawValue)/\(branchName)" }

    /// The branch's worktree directory before a taken one is skipped (`BranchNaming.unused`, which
    /// the sheet applies): nothing while the name field is empty, rather than the type alone that
    /// `BranchNaming.worktreeSlug` falls back to for a bare `feat/`.
    public var worktreeSlug: String {
        branchName.trimmingCharacters(in: .whitespaces).isEmpty ? "" : BranchNaming.worktreeSlug(branch: branch)
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
    /// select — typing `fix/` is picking the type.
    public mutating func setBranch(_ b: String) {
        let split = BranchType.split(b)
        if let split { branchType = split.type; typeEdited = true }
        guard (split?.name ?? b) != branchName else { return }
        branchName = split?.name ?? b; branchEdited = true
    }

    public mutating func setBranchType(_ type: BranchType) {
        guard type != branchType else { return }
        branchType = type; typeEdited = true
    }

    /// Switching model can change which reasoning levels exist, so a level the new model does not
    /// offer becomes that model's default. `efforts` and `defaultEffort` are the agent's own, for a
    /// model that publishes none (AiTerm's `Harness.efforts(for:)` and `defaultEffort(for:)`).
    public mutating func setModel(_ id: String, catalog: [AgentModel], efforts: [String], defaultEffort: String?) {
        model = id
        let picked = catalog.first { $0.id == id }
        if let current = reasoning, (picked?.efforts ?? efforts).contains(current) { return }
        reasoning = picked.map(\.defaultEffort) ?? defaultEffort
    }
}
