import Foundation
import Testing
@testable import ShellforgeCore

/// AiTerm's dividers: named rules between projects, kept by how many projects are above them, and
/// moved — like projects — one drawn step at a time.
@Suite struct SidebarLayoutTests {
    private let a = Project(name: "a", path: "/a"), b = Project(name: "b", path: "/b"), c = Project(name: "c", path: "/c")

    private func names(_ projects: [Project], _ dividers: [SidebarDivider]) -> [String] {
        SidebarLayout.entries(projects: projects, dividers: dividers).map { entry in
            switch entry {
            case .project(let id): projects.first { $0.id == id }!.name
            case .divider(let id): "—" + dividers.first { $0.id == id }!.name
            }
        }
    }

    @Test func dividersDrawBetweenProjectsByPosition() {
        let work = SidebarDivider(name: "Work", position: 1), home = SidebarDivider(name: "Home", position: 9)
        #expect(names([a, b, c], [work, home]) == ["a", "—Work", "b", "c", "—Home"], "a position past the end is the end")
        #expect(names([a, b], [SidebarDivider(name: "Top", position: 0)]) == ["—Top", "a", "b"])
    }

    @Test func dividersMoveAndStopAtTheEnds() {
        var projects = [a, b], dividers = [SidebarDivider(name: "D", position: 0)]
        let d = dividers[0].id
        #expect(!SidebarLayout.canMove(.divider(d), up: true, projects: projects, dividers: dividers))
        #expect(SidebarLayout.move(.divider(d), up: false, projects: &projects, dividers: &dividers))
        #expect(names(projects, dividers) == ["a", "—D", "b"])
        #expect(SidebarLayout.move(.divider(d), up: false, projects: &projects, dividers: &dividers))
        #expect(names(projects, dividers) == ["a", "b", "—D"])
        #expect(!SidebarLayout.move(.divider(d), up: false, projects: &projects, dividers: &dividers), "at the end: nothing")
        #expect(names(projects, dividers) == ["a", "b", "—D"])
    }

    @Test func aProjectCrossesAnAdjacentDivider() {
        var projects = [a, b, c], dividers = [SidebarDivider(name: "D", position: 1)]
        #expect(SidebarLayout.move(.project(b.id), up: true, projects: &projects, dividers: &dividers))
        #expect(names(projects, dividers) == ["a", "b", "—D", "c"], "b crossed the divider; a stays above it")
        #expect(SidebarLayout.move(.project(b.id), up: true, projects: &projects, dividers: &dividers))
        #expect(names(projects, dividers) == ["b", "a", "—D", "c"])
    }

    @Test func projectsSwapWithNoDividerBetween() {
        var projects = [a, b], dividers: [SidebarDivider] = []
        #expect(SidebarLayout.move(.project(a.id), up: false, projects: &projects, dividers: &dividers))
        #expect(projects.map(\.name) == ["b", "a"])
        #expect(!SidebarLayout.canMove(.project(a.id), up: false, projects: projects, dividers: dividers))
    }

    @Test func anOldWorkspaceHasNoDividers() throws {
        let old = #"{"version":1,"projects":[],"tasks":[]}"#
        #expect(try JSONDecoder().decode(Workspace.self, from: Data(old.utf8)).dividers.isEmpty)
        var workspace = Workspace()
        workspace.dividers = [SidebarDivider(name: "Work", position: 0)]
        #expect(try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(workspace)).dividers == workspace.dividers)
    }
}
