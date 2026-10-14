import Foundation
import ShellforgeCore

/// How New Task names a worktree it can continue in: its branch, then where it is and how long
/// since its last commit.
enum ExistingWorktreeLabel {
    /// `<project>/<path in it>` for one inside the project, the whole path for one elsewhere.
    static func place(of worktree: ExistingWorktree, in project: Project) -> String {
        let root = URL(fileURLWithPath: project.path).resolvingSymlinksInPath().path
        let path = URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/") ? project.name + path.dropFirst(root.count) : worktree.path
    }

    /// The select's second line: `.worktrees/x · 3 days ago`.
    static func detail(of worktree: ExistingWorktree, in project: Project, now: Date = Date()) -> String {
        let place = place(of: worktree, in: project)
        let short = place.hasPrefix(project.name + "/") ? String(place.dropFirst(project.name.count + 1)) : place
        guard let commit = worktree.lastCommit else { return short }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return short + " · " + formatter.localizedString(for: commit, relativeTo: now)
    }
}
