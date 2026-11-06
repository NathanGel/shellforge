// Ported from AiTerm (app/Sources/AiTerm/CheckoutMonitor.swift: diffByTask), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

extension SidebarModel {
    /// Reads every shown task's lines against its base, off the main actor, one read at a time; the
    /// app's tick asks every second while the window can be seen, and `DiffStats` keeps each answer
    /// 5 s — 30 s in the `background`, while the app is not active — so git runs at most that often
    /// per worktree however many windows ask. A task in a collapsed project draws no badge and is
    /// not read: its last answer is kept for when the project opens, which reads it at once.
    /// Published only when something changed.
    public func refreshDiffs(background: Bool = false) async {
        guard !readingDiffs else { return }
        readingDiffs = true
        defer { readingDiffs = false }
        let workspace = document.workspace
        let (all, stats) = (workspace.tasks, diffStats)
        let shown = Self.tasksShowingDiffs(in: workspace)
        let read = await BackgroundWork.run { stats.diffs(for: shown, keeping: all, background: background) }
        // A folded task keeps the badge it had; one gone from the workspace loses it.
        let shownIds = Set(shown.map(\.id)), allIds = Set(all.map(\.id))
        var found = read
        for (id, diff) in diffs where !shownIds.contains(id) && allIds.contains(id) { found[id] = diff }
        if found != diffs { diffs = found }
    }

    /// The tasks whose badge can be seen: those of a project that is not collapsed.
    nonisolated static func tasksShowingDiffs(in workspace: Workspace) -> [TaskItem] {
        let open = Set(workspace.projects.filter { !$0.collapsed }.map(\.id))
        return workspace.tasks.filter { open.contains($0.projectId) }
    }
}
