// Ported from AiTerm (docs/keyboard.md: New Task, New Review, Add Project, Focus View, List View,
// and the list's ⌘⌫), GPLv3, Laurens D'Hondt. Shellforge's keys leave iTerm2's alone; the rules
// for what each acts on are AiTerm's.
import Combine
import Foundation
import ShellforgeCore

/// What the sidebar's keyboard shortcuts do (Shellforge/docs/keyboard.md).
public enum SidebarCommand: Int, CaseIterable, Sendable {
    case newTask, newReview, addProject, nextTask, previousTask, removeTask, focusView, listView, newTerminal, addDivider
}

/// A command that needs one of the sidebar's sheets: the view presents it, as its "+" would.
public enum SidebarSheetRequest: Equatable, Sendable {
    case newTask(UUID), newReview(UUID), addProject, removeTask(UUID), newTerminal(UUID), addDivider
}

extension SidebarModel {
    /// What New Task and New Review act on: the selected task's project, else the only project.
    /// With several projects and none of their tasks selected, there is none.
    public var targetProject: UUID? {
        if let id = selectedTaskId, let task = document.workspace.tasks.first(where: { $0.id == id }) { return task.projectId }
        // A terminal row's project, as AiTerm's target is.
        if let id = selectedTerminalId, let terminal = document.workspace.terminals.first(where: { $0.id == id }) { return terminal.projectId }
        return tree.projects.count == 1 ? tree.projects[0].project.id : nil
    }

    /// The tasks waiting on the user — needing input, or done and not yet seen — in sidebar order.
    public var waitingOnYou: [UUID] {
        tree.projects.flatMap(\.tasks).map(\.id)
            .filter { removals[$0] == nil && [.needsInput, .done].contains(status(ofTask: $0)) }
    }

    /// The tasks Next and Previous step through: those of the open projects, in sidebar order.
    var steppableTasks: [UUID] {
        // A task being removed has had its tabs closed: stepping onto it would only open a shell in
        // a worktree on its way out.
        tree.projects.filter { !$0.project.collapsed }.flatMap(\.tasks).map(\.id).filter { removals[$0] == nil }
    }

    public func can(_ command: SidebarCommand) -> Bool {
        switch command {
        case .newTask, .newReview, .newTerminal: targetProject != nil
        case .addProject, .focusView, .listView, .addDivider: true
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
        case .addDivider: sheetRequests.send(.addDivider)
        case .newTerminal: if let project = targetProject { sheetRequests.send(.newTerminal(project)) }
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
        show(task: tasks[next])
    }

    /// AiTerm's Focus View: the projects with a task waiting on the user open, the rest fold, and
    /// the first such task is shown.
    private func focusView() {
        let waiting = Set(waitingOnYou), waitingTerminals = Set(self.waitingTerminals)
        let tasks = document.workspace.tasks, terminals = document.workspace.terminals
        // A project stays open for a task or a terminal waiting in it: folded, either would be out of reach.
        setCollapsed { project in
            !tasks.contains { $0.projectId == project && waiting.contains($0.id) }
                && !terminals.contains { $0.projectId == project && waitingTerminals.contains($0.id) }
        }
        if let first = waitingOnYou.first { show(task: first) }
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

/// The Tasks menu and View's Hide Sidebar, as one list the app builds its menus from: every key is
/// ⌃⌘ and a letter or bracket iTerm2's own `MainMenu.xib` leaves free (⌃⌘F and the ⌃⌘ arrows are
/// iTerm2's; an uppercase key there means ⇧).
public enum SidebarCommandMenu {
    public struct Item: Sendable {
        public let title: String
        public let key: String
        public let modifiers: NSEventModifierFlagsValue
        /// Nil for a separator.
        public let command: SidebarCommand?
    }

    /// `NSEvent.ModifierFlags`, kept to its raw value so ShellforgeUI stays free of AppKit here.
    public struct NSEventModifierFlagsValue: OptionSet, Sendable, Hashable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let control = NSEventModifierFlagsValue(rawValue: 1 << 18)
        public static let command = NSEventModifierFlagsValue(rawValue: 1 << 20)
    }

    private static let keys: NSEventModifierFlagsValue = [.control, .command]

    public static let items: [Item] = [
        Item(title: "New Task…", key: "n", modifiers: keys, command: .newTask),
        Item(title: "New Review…", key: "r", modifiers: keys, command: .newReview),
        Item(title: "New Terminal…", key: "t", modifiers: keys, command: .newTerminal),
        Item(title: "Add Project…", key: "p", modifiers: keys, command: .addProject),
        Item(title: "Add Divider…", key: "d", modifiers: keys, command: .addDivider),
        Item(title: "", key: "", modifiers: [], command: nil),
        Item(title: "Next Task", key: "]", modifiers: keys, command: .nextTask),
        Item(title: "Previous Task", key: "[", modifiers: keys, command: .previousTask),
        Item(title: "Remove Task…", key: "\u{8}", modifiers: keys, command: .removeTask),
        Item(title: "", key: "", modifiers: [], command: nil),
        Item(title: "Focus View", key: "a", modifiers: keys, command: .focusView),
        Item(title: "List View", key: "l", modifiers: keys, command: .listView),
    ]

    /// View › Hide Sidebar (Show Sidebar while hidden), the key Finder and Mail use.
    public static let toggleSidebar = Item(title: "Hide Sidebar", key: "s", modifiers: keys, command: nil)
}

/// Each window's sidebar, so a menu command acts on the key window's and never another's.
@MainActor
public final class SidebarWindows {
    private let models = NSMapTable<AnyObject, SidebarModel>.weakToWeakObjects()

    public init() {}

    public func add(_ model: SidebarModel, for window: AnyObject) { models.setObject(model, forKey: window) }

    public func model(for window: AnyObject?) -> SidebarModel? {
        guard let window else { return nil }
        return models.object(forKey: window)
    }
}
