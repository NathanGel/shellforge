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
        selectedTerminalId = terminal.id
        host.openTab(in: project.path, terminalId: terminal.id, projectId: projectId, title: terminal.name)
    }

    /// Shows the terminal's first tab, or opens one in its project's folder when none is open.
    public func select(terminal id: UUID) {
        guard let node = tree.projects.lazy.flatMap(\.terminals).first(where: { $0.id == id }),
              let project = project(node.terminal.projectId) else { return }
        selectedTerminalId = id
        if let tab = node.tabs.first {
            if tab.id != host.selectedTabId { host.select(tab: tab.id) }
        } else {
            host.openTab(in: project.path, terminalId: id, projectId: project.id, title: node.terminal.name)
        }
    }

    /// AiTerm's Remove Terminal: its tabs closed and the row gone, with no question — nothing on
    /// disk is touched.
    public func removeTerminal(_ id: UUID) {
        _ = host.closeTabs(ofTerminal: id)
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
