import AppKit
import Testing
@testable import ShellforgeUI

@MainActor @Suite struct SidebarTests {
    @Test func theHostViewIsAsWideAsTheSidebar() {
        let view = ShellforgeSidebar.makeView()
        #expect(view.frame.width == ShellforgeSidebar.width)
    }

    @Test func theSidebarStretchesWithTheWindowsHeightOnly() {
        #expect(ShellforgeSidebar.makeView().autoresizingMask == [.height])
    }
}
