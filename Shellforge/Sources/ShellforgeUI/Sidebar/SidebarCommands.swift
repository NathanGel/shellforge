// Ported from AiTerm (docs/keyboard.md: New Task, New Review, Add Project, Focus View, List View,
// and the list's ⌘⌫), GPLv3, Laurens D'Hondt. Shellforge's keys leave iTerm2's alone; the rules
// for what each acts on are AiTerm's.
import Combine
import Foundation
import ShellforgeCore

/// What the sidebar's keyboard shortcuts do (Shellforge/docs/keyboard.md).
public enum SidebarCommand: Int, CaseIterable, Sendable {
    case newTask, newReview, addProject, nextTask, previousTask, removeTask, focusView, listView
}

/// A command that needs one of the sidebar's sheets: the view presents it, as its "+" would.
public enum SidebarSheetRequest: Equatable, Sendable {
    case newTask(UUID), newReview(UUID), addProject, removeTask(UUID)
}

extension SidebarModel {
    /// What New Task and New Review act on: the selected task's project, else the only project.
    /// With several projects and none of their tasks selected, there is none.
    public var targetProject: UUID? {
        if let id = selectedTaskId, let task = document.workspace.tasks.first(where: { $0.id == id }) { return task.projectId }
        return tree.projects.count == 1 ? tree.projects[0].project.id : nil
    }

    /// The tasks waiting on the user — needing input, or done and not yet seen — in sidebar order.
    public var waitingOnYou: [UUID] {
        tree.projects.flatMap(\.tasks).map(\.id).filter { [.needsInput, .done].contains(status(ofTask: $0)) }
    }

    /// The tasks Next and Previous step through: those of the open projects, in sidebar order.
    var steppableTasks: [UUID] {
        tree.projects.filter { !$0.project.collapsed }.flatMap(\.tasks).map(\.id)
    }

    public func can(_ command: SidebarCommand) -> Bool {
        switch command {
        case .newTask, .newReview: targetProject != nil
        case .addProject, .focusView, .listView: true
        case .nextTask, .previousTask: !steppableTasks.isEmpty
        case .removeTask: selectedTaskId != nil
        }
    }

    public func perform(_ command: SidebarCommand) {
        guard can(command) else { return }
        switch command {
        case .newTask: if let project = targetProject { sheetRequests.send(.newTask(project)) }
        case .newReview: if let project = targetProject { sheetRequests.send(.newReview(project)) }
        case .addProject: sheetRequests.send(.addProject)
        case .removeTask: if let task = selectedTaskId { sheetRequests.send(.removeTask(task)) }
        case .nextTask: step(by: 1)
        case .previousTask: step(by: -1)
        case .focusView: focusView()
        case .listView: setCollapsed { _ in false }
        }
    }

    /// The next or previous task, wrapping round; from no selection, the first or the last.
    private func step(by offset: Int) {
        let tasks = steppableTasks
        guard !tasks.isEmpty else { return }
        let next: Int
        if let current = selectedTaskId, let index = tasks.firstIndex(of: current) {
            next = (index + offset + tasks.count) % tasks.count
        } else {
            next = offset > 0 ? 0 : tasks.count - 1
        }
        select(task: tasks[next])
    }

    /// AiTerm's Focus View: the projects with a task waiting on the user open, the rest fold, and
    /// the first such task is shown.
    private func focusView() {
        let waiting = Set(waitingOnYou)
        let tasks = document.workspace.tasks
        setCollapsed { project in !tasks.contains { $0.projectId == project && waiting.contains($0.id) } }
        if let first = waitingOnYou.first { select(task: first) }
    }

    private func setCollapsed(_ collapsed: (UUID) -> Bool) {
        do {
            try document.update { workspace in
                for i in workspace.projects.indices { workspace.projects[i].collapsed = collapsed(workspace.projects[i].id) }
            }
        } catch {
            lastError = String(describing: error)
        }
    }
}
