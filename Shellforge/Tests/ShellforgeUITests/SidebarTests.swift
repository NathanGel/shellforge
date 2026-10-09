import AppKit
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct SidebarTests {
    private func sidebarModel() throws -> SidebarModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-view-\(UUID().uuidString)")
        return SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: try GitRepoForUI().launcher)
    }

    /// An Agent hooks sheet on a scratch home: building the view reads no file.
    private func hooks() -> AgentHooksModel {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-view-home-\(UUID().uuidString)")
        return AgentHooksModel(integrations: HookIntegrations(home: home, resources: .bundled(resourceURL: nil)), names: [:])
    }

    @Test func theHostViewIsAsWideAsTheSidebar() throws {
        #expect(ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }, hooks: hooks()).frame.width == ShellforgeSidebar.width)
    }

    @Test func theSidebarStretchesWithTheWindowsHeightOnly() throws {
        #expect(ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }, hooks: hooks()).autoresizingMask == [.height])
    }
}
