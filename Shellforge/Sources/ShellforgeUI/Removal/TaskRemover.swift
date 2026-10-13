// Ported from AiTerm (app/Sources/AiTerm/TaskRemover.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// What a task's row says about its removal: running, or why the last one stopped.
public enum RowRemoval: Equatable, Sendable {
    case removing
    case stopped(String)
}

/// The person's Remove, as AiTerm's `TaskRemover` takes it: asked first, with "Also delete
/// branch"; uncommitted work asked about while the tabs are still open; the task's tabs closed
/// before git deletes its worktree, so nothing running there writes files back into it; the branch
/// when asked, a branch with commits its base lacks kept unless the person agrees to lose them; and
/// the row last.
///
/// Shellforge has no banners with buttons and no toasts: a kept branch is asked about at once, and
/// a finished removal says nothing — its row goes.
extension SidebarModel {
    /// True when the task was removed. One removal per task at a time: a second Remove while the
    /// first is asking or running does nothing.
    ///
    /// `closingFirst`: the tab a Close Tab started this from. Once Remove is confirmed it closes as
    /// Close Tab closes it — a running job asks — and a refusal stops the removal there.
    @discardableResult
    public func confirmRemove(taskId id: UUID, closingFirst tab: String? = nil, paneOnly: Bool = false) async -> Bool {
        guard !removalBoard.asking.contains(id), removalBoard.removals[id] != .removing,
              let shown = document.workspace.tasks.first(where: { $0.id == id }),
              document.workspace.projects.contains(where: { $0.id == shown.projectId }) else { return false }
        removalBoard.asking.insert(id)
        defer { removalBoard.asking.remove(id) }
        let isReview = shown.kind == .review
        // A review's branch is the merge request's: its Remove never offers to delete it — the
        // removal releases it only when nothing would be lost.
        let answer = await prompter.ask(AlertPrompt(
            message: "Remove \(isReview ? "review" : "task") “\(shown.title)”?",
            detail: isReview
                ? "Deletes the worktree and closes its tabs. Its local branch goes too, unless it has commits origin lacks:\n\n\(shown.worktreePath)"
                : "Deletes the worktree and closes its tabs:\n\n\(shown.worktreePath)",
            buttons: ["Remove", "Cancel"],
            checkbox: isReview ? nil : "Also delete branch \(shown.branch)",
            defaultDeletes: true))
        // Decided on the task as it is once answered: across the await it, or its project, can be gone.
        guard answer.confirmed, let task = document.workspace.tasks.first(where: { $0.id == id }),
              let project = document.workspace.projects.first(where: { $0.id == task.projectId }) else { return false }
        removalBoard.removals[id] = .removing
        do {
            var force = false
            let launcher = self.launcher
            if try await BackgroundWork.run({ try TaskRemoval.hasUnsavedWork(task: task, project: project, launcher: launcher) }) {
                // Keeping is the default, on ↩ and ⎋ both; deleting is the plain grey button beside it.
                let unsaved = await prompter.ask(AlertPrompt(
                    message: "The worktree has uncommitted changes",
                    detail: "Removing this worktree permanently deletes its uncommitted changes and untracked files.",
                    buttons: ["Keep \(task.kindName)", "Delete Changes and Remove"], escape: 0))
                guard unsaved.button == 1 else { removalBoard.removals[id] = nil; return false }
                force = true
            }
            if let tab, !(paneOnly ? host.closePane(ofTab: tab) : host.close(tab: tab)) {
                removalBoard.removals[id] = nil
                return false
            }
            guard host.closeTabs(ofTask: id) else {
                removalBoard.removals[id] = .stopped("Not removed: its tabs did not close")
                lastError = "Couldn’t remove the task. Its tabs did not close, so nothing was deleted."
                return false
            }
            let forced = force, deleteBranch = answer.checked
            let result = try await BackgroundWork.run {
                try TaskRemoval.remove(task: task, project: project, deleteBranch: deleteBranch, force: forced, launcher: launcher)
            }
            await settleBranch(of: task, in: project, after: result)
            try document.update { $0.tasks.removeAll { $0.id == id } }
            removalBoard.removals[id] = nil
            return true
        } catch {
            removalBoard.removals[id] = .stopped("Not removed")
            lastError = "Couldn’t remove the task. " + Self.reason(of: error)
            return false
        }
    }

    /// The worktree is gone: a branch git kept is asked about now, or said why it stayed. The task
    /// goes either way.
    private func settleBranch(of task: TaskItem, in project: Project, after result: TaskRemoval.Removed) async {
        if let kept = result.keptBranch { lastError = kept.note(branch: task.branch) }
        switch result.branchRefusal {
        case nil:
            return
        case .notMerged(let base)?:
            let answer = await prompter.ask(AlertPrompt(
                message: "Delete branch \(task.branch)?",
                detail: "It has commits that aren’t on \(base.isEmpty ? "its base" : base). Deleting the branch deletes them too.",
                // Asked straight after Remove, so ↩ pressed twice must not lose commits: keeping is
                // the default, on ↩ and ⎋ both, as Keep Task is.
                buttons: ["Keep Branch", "Delete Branch"], escape: 0))
            guard answer.button == 1 else { return }
            let launcher = self.launcher
            do {
                try await BackgroundWork.run { try TaskRemoval.deleteUnmergedBranch(of: task, in: project, launcher: launcher) }
            } catch {
                lastError = "Branch \(task.branch) kept: " + Self.reason(of: error)
            }
        case .other(let reason)?:
            lastError = "Branch \(task.branch) kept: \(reason)"
        }
    }

    /// git's own words, first line: what it refused and why.
    static func reason(of error: Error) -> String {
        let text = (error as? GitFailure)?.message ?? (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.split(separator: "\n").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? text
    }
}
