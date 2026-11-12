import Foundation
import ShellforgeCore

/// How a branch switch ended: the folder is on the branch, or the person chose the worktree that
/// already has it checked out.
public enum BranchSwitchResult: Equatable, Sendable {
    case switched
    case useWorktree(path: String)
}

/// Puts a project's own folder on another branch, asking first whenever git can’t simply do it:
/// a branch that doesn’t exist yet, another task working in the folder, changes that clash. New
/// Task asks this for a Project folder task, the Git panel for Switch Branch. Cancel throws
/// `CreationDeclined`, with the folder as it was.
@MainActor
public struct BranchSwitchFlow {
    private let prompter: Prompter
    private let launcher: CommandLauncher

    public init(prompter: Prompter, launcher: CommandLauncher) {
        self.prompter = prompter
        self.launcher = launcher
    }

    /// `busyTask` gives the title of a task working in the folder, asked about before anything
    /// changes; it is read just before that question, after any earlier one was answered. `stashLabel` follows “Shellforge: before” in the stash’s message. With
    /// `offerOtherWorktree`, a branch checked out in another worktree offers that worktree;
    /// without, it is only reported.
    public func switchProject(_ project: Project, to branch: String, busyTask: @MainActor () -> String?, stashLabel: String,
                              offerOtherWorktree: Bool) async throws -> BranchSwitchResult {
        let launcher = self.launcher
        let obstacle = try await BackgroundWork.run { try ProjectFolderSwitch.check(branch, in: project, launcher: launcher) }
        switch obstacle {
        case .elsewhere(let path):
            guard offerOtherWorktree else {
                _ = await prompter.ask(AlertPrompt(message: "“\(branch)” is checked out in another worktree.",
                                                   detail: "Git keeps a branch to one worktree at a time: \(path)",
                                                   buttons: ["OK"]))
                throw CreationDeclined()
            }
            try await confirm(AlertPrompt(message: "“\(branch)” is checked out in another worktree.",
                                          detail: "Git keeps a branch to one worktree at a time. The task can work there instead: \(path)",
                                          buttons: ["Use That Worktree", "Cancel"]))
            return .useWorktree(path: path)
        case .missing:
            try await confirm(AlertPrompt(message: "“\(branch)” doesn’t exist yet.",
                                          detail: "Create it from the branch \(project.name) has checked out now, and switch to it?",
                                          buttons: ["Create Branch", "Cancel"]))
        case nil:
            break
        }
        let create = obstacle == .missing
        if let busy = busyTask() {
            try await confirm(AlertPrompt(message: "“\(busy)” is also working in this folder.",
                                          detail: "Switching to \(branch) changes the files under it while it works.",
                                          buttons: ["Switch Anyway", "Cancel"]))
        }
        let first = try await BackgroundWork.run {
            try ProjectFolderSwitch.perform(branch, in: project, create: create, stash: nil, launcher: launcher)
        }
        if first == .blockedByChanges {
            let message = ProjectFolderSwitch.stashMessage(before: stashLabel)
            try await confirm(AlertPrompt(message: "Uncommitted changes in \(project.name) clash with “\(branch)”.",
                                          detail: "Stash them to switch. They stay in git’s stash as \(message), and git stash pop brings them back.",
                                          buttons: ["Stash and Switch", "Cancel"]))
            // With the changes stashed, git switches or throws its own reason, the changes put back.
            _ = try await BackgroundWork.run {
                try ProjectFolderSwitch.perform(branch, in: project, create: create, stash: message, launcher: launcher)
            }
        }
        return .switched
    }

    /// The default button goes on; anything else stops the switch.
    private func confirm(_ prompt: AlertPrompt) async throws {
        guard await prompter.ask(prompt).confirmed else { throw CreationDeclined() }
    }
}
