import AppKit
import Testing
@testable import ShellforgeUI

/// Whether a window's sidebar can be seen: the app's tick reads git for its badges, and samples
/// the Mac for its footer, only while one can.
@MainActor @Suite struct SidebarVisibilityTests {
    @Test func aSidebarShowsOnlyInAWindowOnScreenAndUncovered() {
        #expect(SidebarVisibility.isShowing(viewHidden: false, windowVisible: true, miniaturized: false, occlusion: .visible))
        #expect(!SidebarVisibility.isShowing(viewHidden: true, windowVisible: true, miniaturized: false, occlusion: .visible),
                "closed with ⌃⌘S")
        #expect(!SidebarVisibility.isShowing(viewHidden: false, windowVisible: false, miniaturized: false, occlusion: .visible))
        #expect(!SidebarVisibility.isShowing(viewHidden: false, windowVisible: true, miniaturized: true, occlusion: .visible))
        #expect(!SidebarVisibility.isShowing(viewHidden: false, windowVisible: true, miniaturized: false, occlusion: []),
                "wholly covered")
    }

    @Test func aViewInNoWindowIsNotShowing() {
        #expect(!SidebarVisibility.isShowing(NSView()))
    }
}
