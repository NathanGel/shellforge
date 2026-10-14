// Ported from AiTerm (app/Sources/AiTerm/ProjectActions.swift: confirmRemove, busyReason,
// refuseRemoval), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// Remove Project… only forgets the project, as AiTerm's does: its tasks and terminals go from the
/// sidebar, and no git command runs. Worktrees stay on disk — the alert lists them, so nothing
/// disappears silently — and its tabs stay open, under Other tabs. A running tunnel no other
/// project lists is stopped: its row went with the project.
extension SidebarModel {
    /// True when the project was removed.
    @discardableResult
    public func confirmRemove(project id: UUID) async -> Bool {
        guard let project = project(id) else { return false }
        if let busy = busyReason(of: id) { await refuseRemoval(of: project, because: busy); return false }
        let paths = document.workspace.tasks.filter { $0.projectId == id }.map(\.worktreePath)
        let answer = await prompter.ask(AlertPrompt(
            message: "Remove project “\(project.name)”?",
            detail: paths.isEmpty
                ? "Removes the project from Shellforge. Files are kept and tabs stay open."
                : "Removes the project, tasks, and terminals from Shellforge. Files and tabs are kept, including these worktrees:\n\n"
                    + paths.joined(separator: "\n"),
            buttons: ["Remove", "Cancel"]))
        // Anything can run across the await, a create in the project among them, so it is asked
        // again — and acted on in the same turn, with nothing able to start in between.
        guard answer.confirmed, self.project(id) != nil else { return false }
        if let busy = busyReason(of: id) { await refuseRemoval(of: project, because: busy); return false }
        do {
            try document.update { workspace in
                guard let index = workspace.projects.firstIndex(where: { $0.id == id }) else { return }
                workspace.projects.remove(at: index)
                workspace.tasks.removeAll { $0.projectId == id }
                workspace.terminals.removeAll { $0.projectId == id }
                workspace.lastAgentByProject[id] = nil
                workspace.lastOpenSSHByProject[id] = nil
                // A divider counts the projects above it: one below the removed project moves up one.
                for i in workspace.dividers.indices where workspace.dividers[i].position > index {
                    workspace.dividers[i].position -= 1
                }
            }
        } catch {
            lastError = "Couldn’t remove the project. " + Self.reason(of: error)
            return false
        }
        stopOrphaned(project.tunnels)
        return true
    }

    /// Runs `create` with the project held: Remove Project refuses until it ends.
    func whileCreating<T>(in projectId: UUID, _ create: () async throws -> T) async rethrows -> T {
        removalBoard.creating[projectId, default: 0] += 1
        defer {
            let left = removalBoard.creating[projectId, default: 1] - 1
            removalBoard.creating[projectId] = left > 0 ? left : nil
        }
        return try await create()
    }

    /// Why the project cannot be removed yet, if it cannot: work still in flight would land in a
    /// project that is gone. Synchronous, so the caller that finds nothing removes it at once.
    private func busyReason(of id: UUID) -> String? {
        if removalBoard.creating[id, default: 0] > 0 { return "A task is still being created in it." }
        let tasks = document.workspace.tasks.filter { $0.projectId == id }.map(\.id)
        if tasks.contains(where: { removalBoard.asking.contains($0) || removalBoard.removals[$0] == .removing }) {
            return "A task is still being removed."
        }
        return nil
    }

    private func refuseRemoval(of project: Project, because busy: String) async {
        _ = await prompter.ask(AlertPrompt(message: "“\(project.name)” can’t be removed yet", detail: busy + " Try again in a moment."))
    }
}
