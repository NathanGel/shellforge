// Ported from AiTerm (app/Sources/AiTerm/CheckoutMonitor.swift: diffByTask), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

extension SidebarModel {
    /// Reads every task's lines against its base, off the main actor, one read at a time; the app's
    /// tick asks every second, and `DiffStats` keeps each answer 5 s, so git runs at most that often
    /// per worktree however many windows ask. Published only when something changed.
    public func refreshDiffs() async {
        guard !readingDiffs else { return }
        readingDiffs = true
        defer { readingDiffs = false }
        let (tasks, stats) = (document.workspace.tasks, diffStats)
        let found = await BackgroundWork.run { stats.diffs(for: tasks) }
        if found != diffs { diffs = found }
    }

}
