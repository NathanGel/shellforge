import AppKit
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct SidebarTests {
    private func sidebarModel() throws -> SidebarModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-view-\(UUID().uuidString)")
        return SidebarModel(host: FakeTerminalHost(), store: WorkspaceStore(folder: folder), launcher: try GitRepoForUI().launcher)
    }

    @Test func theHostViewIsAsWideAsTheSidebar() throws {
        #expect(ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }).frame.width == ShellforgeSidebar.width)
    }

    @Test func theSidebarStretchesWithTheWindowsHeightOnly() throws {
        #expect(ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }).autoresizingMask == [.height])
    }
}
