import Foundation
import ShellforgeCore

/// Rearrange mode: the sidebar's order is edited as a draft and written once, on Done.
extension SidebarModel {
    public var isRearranging: Bool { rearrange != nil }

    /// Only one window rearranges at a time, so two drafts never race to save.
    public var canRearrange: Bool {
        rearrange == nil && (document.rearranger == nil || document.rearranger === self)
    }

    public func beginRearrange() {
        guard canRearrange else { return }
        rearrange = RearrangeDraft(document.workspace)
        document.rearranger = self
    }

    /// Saves the draft's order. A failed save is said and leaves the mode open, so nothing is lost.
    public func finishRearrange() {
        guard let draft = rearrange else { return }
        var saved = false
        attempt {
            try document.update { draft.apply(to: &$0) }
            saved = true
        }
        if saved { leaveRearrange() }
    }

    public func cancelRearrange() {
        leaveRearrange()
    }

    @discardableResult
    public func moveInDraft(_ item: RearrangeDraft.Item, before: RearrangeDraft.Item?) -> Bool {
        rearrange?.move(item, before: before) ?? false
    }

    public func stepInDraft(_ item: RearrangeDraft.Item, up: Bool) {
        rearrange?.step(item, up: up)
    }

    private func leaveRearrange() {
        rearrange = nil
        draggingProject = nil
        if document.rearranger === self { document.rearranger = nil }
    }

    /// The rows while rearranging: each project, its SSH rows, then its tasks and terminals, all in
    /// the draft's order. No tabs and no Other tabs; a folded or dragged project shows its header only.
    func rearrangeRows(_ draft: RearrangeDraft) -> [SidebarRow] {
        let workspace = document.workspace
        let nodes = Dictionary(tree.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dividers = Dictionary(workspace.dividers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [SidebarRow] = []
        for (index, entry) in draft.entries.enumerated() {
            switch entry {
            case .divider(let id):
                if let divider = dividers[id] {
                    rows.append(.divider(DividerRowItem(divider: divider, canMoveUp: index > 0, canMoveDown: index < draft.entries.count - 1)))
                }
            case .project(let id):
                guard let node = nodes[id] else { continue }
                rows.append(.project(node, collapsed: node.project.collapsed))
                guard !node.project.collapsed, draggingProject != id else { continue }
                let tunnelsByAlias = Dictionary(tunnelRows(of: node.project).map { ($0.alias, $0) }, uniquingKeysWith: { first, _ in first })
                rows += (draft.tunnels[id] ?? []).compactMap { tunnelsByAlias[$0] }.map(SidebarRow.tunnel)
                let tasks = Dictionary(node.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let terminals = Dictionary(node.terminals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for child in draft.children[id] ?? [] {
                    switch child {
                    case .task(let taskId):
                        if let task = tasks[taskId] { rows.append(.task(task, selected: task.id == selectedTaskId)) }
                    case .terminal(let terminalId):
                        if let terminal = terminals[terminalId] { rows.append(.terminal(terminal, selected: terminal.id == selectedTerminalId)) }
                    }
                }
            }
        }
        return tree.projects.isEmpty ? [.empty] : rows
    }
}
