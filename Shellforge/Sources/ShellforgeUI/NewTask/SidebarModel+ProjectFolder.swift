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
        do {
            return try await switchProjectFolder(draft: draft, branch: branch, project: project, taken: taken)
        } catch {
            // A Cancel answered or a create stopped is no problem; anything else is.
            if !(error is CreationDeclined || error is CreationCancelled || error is CancellationError) {
                ErrorLogging.record("projectFolder", "Switching \(project.path) to \(branch) failed: \(error)")
            }
            throw error
        }
    }

    private func switchProjectFolder(draft: TaskDraft, branch: String, project: Project, taken: [String]) async throws -> TaskDraft {
        let busy = tree.projects.first(where: { $0.id == project.id })?.tasks.first(where: {
            !$0.tabs.isEmpty && ProjectFolderTasks.isProjectFolder($0.task, in: project)
        })
        let flow = BranchSwitchFlow(prompter: prompter, launcher: launcher)
        let result = try await flow.switchProject(project, to: branch, busyTask: busy?.task.title,
                                                  stashLabel: "“\(draft.title)”", offerOtherWorktree: true)
        switch result {
        case .useWorktree(let path):
            let launcher = self.launcher
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
        case .switched:
            folderLog.info("Switched a project folder to another branch for a Project folder task")
            var next = draft
            next.folderBranch = nil
            return next
        }
    }
}

/// A question asked during a create was answered Cancel: nothing was made, nothing needs saying,
/// and the sheet stays open so the draft can be changed and tried again.
public struct CreationDeclined: Error, Equatable {
    public init() {}
}
