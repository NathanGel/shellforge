import Foundation
import os
import ShellforgeCore

private let folderLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "projectFolder")

extension SidebarModel {
    /// A Project folder task on another branch: the folder is switched to it before the task is made,
    /// asking first whenever git can’t simply do it. Returns the draft to make, which is an Existing
    /// worktree draft when the branch lives in another worktree and the person chose that one.
    /// Cancel throws `CreationDeclined`, with the folder as it was and the sheet still open.
    func prepareProjectFolder(draft: TaskDraft, branch: String, project: Project, taken: [String]) async throws -> TaskDraft {
        let launcher = self.launcher
        let obstacle = try await BackgroundWork.run { try ProjectFolderSwitch.check(branch, in: project, launcher: launcher) }
        switch obstacle {
        case .elsewhere(let path):
            try await confirm(AlertPrompt(message: "“\(branch)” is checked out in another worktree.",
                                          detail: "Git keeps a branch to one worktree at a time. The task can work there instead: \(path)",
                                          buttons: ["Use That Worktree", "Cancel"]))
            let listed = try await BackgroundWork.run { try ExistingWorktrees.list(project: project, taken: taken, launcher: launcher) }
            let wanted = ExistingWorktrees.resolved(path)
            // A worktree another task already works in is not offered for a second one.
            guard let worktree = listed.first(where: { ExistingWorktrees.resolved($0.path) == wanted }) else {
                throw ExistingWorktrees.Refusal.taken(branch)
            }
            var next = draft
            next.choose(.existing)
            next.pick(existing: worktree)
            return next
        case .missing:
            try await confirm(AlertPrompt(message: "“\(branch)” doesn’t exist yet.",
                                          detail: "Create it from the branch \(project.name) has checked out now, and switch to it?",
                                          buttons: ["Create Branch", "Cancel"]))
        case nil:
            break
        }
        let create = obstacle == .missing
        if let busy = tree.projects.first(where: { $0.id == project.id })?.tasks.first(where: {
            !$0.tabs.isEmpty && ProjectFolderTasks.isProjectFolder($0.task, in: project)
        }) {
            try await confirm(AlertPrompt(message: "“\(busy.task.title)” is also working in this folder.",
                                          detail: "Switching to \(branch) changes the files under it while it works.",
                                          buttons: ["Switch Anyway", "Cancel"]))
        }
        let first = try await BackgroundWork.run {
            try ProjectFolderSwitch.perform(branch, in: project, create: create, stash: nil, launcher: launcher)
        }
        if first == .blockedByChanges {
            let message = ProjectFolderSwitch.stashMessage(task: draft.title)
            try await confirm(AlertPrompt(message: "Uncommitted changes in \(project.name) clash with “\(branch)”.",
                                          detail: "Stash them to switch. They stay in git’s stash as \(message), and git stash pop brings them back.",
                                          buttons: ["Stash and Switch", "Cancel"]))
            // With the changes stashed, git switches or throws its own reason, the changes put back.
            _ = try await BackgroundWork.run {
                try ProjectFolderSwitch.perform(branch, in: project, create: create, stash: message, launcher: launcher)
            }
        }
        folderLog.info("Switched a project folder to another branch for a Project folder task")
        var next = draft
        next.folderBranch = nil
        return next
    }

    /// The default button goes on; anything else stops the create, with the sheet left open.
    private func confirm(_ prompt: AlertPrompt) async throws {
        guard await prompter.ask(prompt).confirmed else { throw CreationDeclined() }
    }
}

/// A question asked during a create was answered Cancel: nothing was made, nothing needs saying,
/// and the sheet stays open so the draft can be changed and tried again.
public struct CreationDeclined: Error, Equatable {
    public init() {}
}
