// Ported from AiTerm (app/Sources/AiTerm/TerminalActions.swift, ProjectActions.swift: rename),
// GPLv3, Laurens D'Hondt. A Shellforge terminal is a tab rather than a window: selecting a row
// with none open opens one, as a task's does, in place of AiTerm's Reopen Window.
import Foundation
import ShellforgeCore

extension SidebarModel {
    /// AiTerm's default name: "Terminal", then the lowest free "Terminal n" in the project.
    public func suggestedTerminalName(in projectId: UUID) -> String {
        TerminalItem.suggestedName(taken: document.workspace.terminals.filter { $0.projectId == projectId }.map(\.name))
    }

    /// A terminal row and its first tab: a plain shell in the project's folder. An empty name takes
    /// the suggested one.
    public func newTerminal(name: String, in projectId: UUID) {
        guard let project = project(projectId) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let terminal = TerminalItem(projectId: projectId, name: trimmed.isEmpty ? suggestedTerminalName(in: projectId) : trimmed)
        do {
            try document.update { workspace in
                workspace.terminals.append(terminal)
                if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].collapsed = false }
            }
        } catch {
            lastError = String(describing: error)
            return
        }
        selectTerminalRow(terminal.id)
        host.openTab(in: project.path, terminalId: terminal.id, projectId: projectId, title: terminal.name)
    }

    /// Shows the terminal's first tab, or opens one in its project's folder when none is open.
    public func select(terminal id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.terminals).first(where: { $0.id == id }),
              let project = project(node.terminal.projectId) else { return }
        shown(terminal: id, explicit: true)
        if let tab = node.tabs.first {
            if tab.id != host.selectedTabId { host.select(tab: tab.id) }
        } else {
            host.openTab(in: project.path, terminalId: id, projectId: project.id, title: node.terminal.name)
        }
    }

    /// AiTerm's Remove Terminal: its tabs closed and the row gone, with no question — nothing on
    /// disk is touched.
    public func removeTerminal(_ id: UUID) {
        // A tab iTerm2 would not close stays the terminal's, row and all: dropped, it would be an
        // unowned "other tab".
        guard host.closeTabs(ofTerminal: id) else {
            lastError = "The terminal’s tab didn’t close, so its row stays. Close the tab, then remove it again."
            return
        }
        do {
            try document.update { $0.terminals.removeAll { $0.id == id } }
        } catch {
            lastError = String(describing: error)
        }
        if selectedTerminalId == id { selectedTerminalId = nil }
    }

    /// Renames the row only; its tabs keep their titles. An empty name keeps the old one.
    public func renameTerminal(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try document.update { workspace in
                if let i = workspace.terminals.firstIndex(where: { $0.id == id }) { workspace.terminals[i].name = trimmed }
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// AiTerm's task rename: the title only — the branch, the worktree and the tabs keep theirs.
    /// An empty name keeps the old one.
    public func renameTask(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try document.update { workspace in
                if let i = workspace.tasks.firstIndex(where: { $0.id == id }) { workspace.tasks[i].title = trimmed }
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// The terminals whose tabs in this window wait on you: needing input, or done and unseen.
    public var waitingTerminals: [UUID] {
        tree.projects.flatMap(\.terminals).map(\.id).filter { [.needsInput, .done].contains(status(ofTerminal: $0)) }
    }

    /// The state of each terminal with a tab in this window, from those tabs alone. A terminal's
    /// state for the app combines every window's (DockBadge).
    public var terminalStates: [UUID: SessionState] {
        Dictionary(tree.projects.flatMap(\.terminals).filter { !$0.tabs.isEmpty }.map { ($0.id, status(ofTerminal: $0.id)) },
                   uniquingKeysWith: { first, _ in first })
    }

    /// Focus View's way to a terminal: its tab in this window when it has one, else only the row —
    /// it opens nothing, as stepping to a task does not.
    public func show(terminal id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.terminals).first(where: { $0.id == id }) else { return }
        shown(terminal: id, explicit: true)
        if let tab = node.tabs.first, tab.id != host.selectedTabId { host.select(tab: tab.id) }
    }

    /// The terminal the user is now looking at. A done one has been seen, as a task is: its tabs'
    /// sessions, by id — they carry no task for the daemon to find them by.
    func shown(terminal id: UUID, explicit: Bool) {
        let changed = selectedTerminalId != id
        selectTerminalRow(id)
        guard explicit || changed, status(ofTerminal: id) == .done else { return }
        feed?.markSeen(sessions: tabs(ofTerminal: id).flatMap { sessions.sessions(ofTab: $0.id) }.map(\.sessionId))
    }

    /// The agents in the terminal's tabs, in tab order.
    public func avatars(forTerminal id: UUID) -> [SessionAgent] {
        tabs(ofTerminal: id).flatMap { avatars(forTab: $0.id) }
    }

    /// The most urgent state among its tabs; idle with none.
    public func status(ofTerminal id: UUID) -> SessionState {
        TaskStatus.aggregate(tabs(ofTerminal: id).map { status(ofTab: $0.id) })
    }

    private func tabs(ofTerminal id: UUID) -> [TabSnapshot] {
        tree.projects.lazy.flatMap(\.terminals).first { $0.id == id }?.tabs ?? []
    }
}
