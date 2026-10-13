// Ported from AiTerm (app/Sources/AiTermCore/Models.swift: SidebarDivider, AppState.move),
// GPLv3, Laurens D'Hondt. AiTerm keeps one ordered list of projects and dividers; Shellforge keeps
// its projects' order and gives each divider the number of projects above it, with the same moves.
import Foundation

/// A named rule between projects: a label, not a container. An empty name draws a plain rule.
public struct SidebarDivider: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// How many projects are above it; past the end is the end. Dividers at one position keep the
    /// order they are saved in.
    public var position: Int

    public init(id: UUID = UUID(), name: String, position: Int) {
        self.id = id; self.name = name; self.position = position
    }
}

/// One drawn item at the sidebar's top level.
public enum SidebarEntry: Equatable, Hashable, Sendable {
    case project(UUID), divider(UUID)
}

public enum SidebarLayout {
    /// The projects and dividers in drawing order.
    public static func entries(projects: [Project], dividers: [SidebarDivider]) -> [SidebarEntry] {
        var entries: [SidebarEntry] = []
        for index in 0...projects.count {
            entries += dividers.filter { min(max($0.position, 0), projects.count) == index }.map { .divider($0.id) }
            if index < projects.count { entries.append(.project(projects[index].id)) }
        }
        return entries
    }

    public static func canMove(_ entry: SidebarEntry, up: Bool, projects: [Project], dividers: [SidebarDivider]) -> Bool {
        let all = entries(projects: projects, dividers: dividers)
        guard let index = all.firstIndex(of: entry) else { return false }
        return up ? index > 0 : index < all.count - 1
    }

    /// AiTerm's move: the entry swaps with the one drawn next to it, so a project crosses an
    /// adjacent divider rather than jumping to the next project. False, and nothing changed, at an end.
    @discardableResult
    public static func move(_ entry: SidebarEntry, up: Bool, projects: inout [Project], dividers: inout [SidebarDivider]) -> Bool {
        var all = entries(projects: projects, dividers: dividers)
        guard let index = all.firstIndex(of: entry) else { return false }
        let other = up ? index - 1 : index + 1
        guard all.indices.contains(other) else { return false }
        all.swapAt(index, other)
        // Read the order back: projects as drawn, each divider at the count of projects above it.
        // A hand-edited workspace may repeat an id: the first is kept, never a crash.
        let byProject = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byDivider = Dictionary(dividers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var newProjects: [Project] = [], newDividers: [SidebarDivider] = []
        for item in all {
            switch item {
            case .project(let id): if let project = byProject[id] { newProjects.append(project) }
            case .divider(let id):
                if var divider = byDivider[id] {
                    divider.position = newProjects.count
                    newDividers.append(divider)
                }
            }
        }
        projects = newProjects
        dividers = newDividers
        return true
    }
}
