// Ported from AiTerm (app/Sources/AiTerm/Views/DestinationLine.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeCore
import ShellforgeDesign

/// Where a sheet's window opens, in the one format every such sheet uses:
/// `Opens in Shellforge · <project>/<worktree path in it, if any> · <branch>` — Shellforge is the
/// terminal now, where AiTerm said iTerm2.
/// A branch not known — none named yet, or a detached checkout New Terminal asked git about before
/// the checkout monitor's first pass (after it, the monitor names one by its short sha) — is left
/// out rather than drawn empty.
struct Destination: Equatable {
    /// What stands between "Opens in iTerm2" and the branch.
    let place: String
    let branch: String

    /// A new worktree, `slug`, in the project's worktree directory: New Task and New Review.
    static func worktree(project: Project, slug: String, branch: String) -> Destination {
        Destination(place: "\(project.name)/.worktrees/\(slug)", branch: branch)
    }

    /// A worktree that already exists: inside the project, by its path there; elsewhere, whole.
    static func existing(project: Project, worktree: ExistingWorktree) -> Destination {
        Destination(place: ExistingWorktreeLabel.place(of: worktree, in: project), branch: worktree.branch)
    }

    /// The project folder itself: New Terminal.
    static func projectFolder(_ project: Project, branch: String) -> Destination {
        Destination(place: project.name, branch: branch)
    }

    /// The New Task and New Review steps that end on the line: step 1, which names the checkout,
    /// and step 3, which creates it. Step 2 is the agent's alone, so nothing works the line out there
    /// — finding the unused worktree slug looks at the disk.
    static func isShown(onStep step: Int) -> Bool { step != 2 }

    var text: String {
        (["Opens in Shellforge", place] + (branch.isEmpty ? [] : [branch])).joined(separator: " · ")
    }
}

/// The line that ends the content of every sheet that opens a window — New Task and New Review on
/// steps 1 and 3, and New Terminal — saying where it opens. One `HelpText`, wrapping onto a second
/// line for a long worktree path and its branch; past that it is cut in the middle, so the branch
/// at its end survives, and the tooltip has the whole line.
struct DestinationLine: View {
    let destination: Destination
    init(_ destination: Destination) { self.destination = destination }

    var body: some View {
        HelpText(destination.text).lineLimit(2).truncationMode(.middle).help(destination.text)
    }
}
