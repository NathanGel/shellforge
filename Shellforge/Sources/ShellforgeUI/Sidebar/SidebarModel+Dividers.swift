// Ported from AiTerm (app/Sources/AiTerm/ProjectActions.swift: addDivider, rename(divider:),
// removeDivider), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

extension SidebarModel {
    /// AiTerm's Add Divider: appended at the end. An empty name draws a plain rule.
    public func addDivider(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateLayout { _, dividers, count in dividers.append(SidebarDivider(name: trimmed, position: count)) }
    }

    /// Renames it; empty is allowed, and draws a plain rule.
    public func renameDivider(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateLayout { _, dividers, _ in
            if let i = dividers.firstIndex(where: { $0.id == id }) { dividers[i].name = trimmed }
        }
    }

    /// Removes it with no question: it holds nothing but its label.
    public func removeDivider(_ id: UUID) {
        updateLayout { _, dividers, _ in dividers.removeAll { $0.id == id } }
    }

    private func updateLayout(_ change: (inout [Project], inout [SidebarDivider], Int) -> Void) {
        do {
            try document.update { workspace in change(&workspace.projects, &workspace.dividers, workspace.projects.count) }
        } catch {
            lastError = String(describing: error)
        }
    }
}
