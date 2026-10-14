import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeDesign
@testable import ShellforgeUI

/// The sidebar's text size, stepped with ⌘+ / ⌘− / ⌘0 through the three sizes and remembered.
/// Each test has a defaults suite of its own.
@MainActor @Suite struct SidebarZoomTests {
    @Test func aNewZoomIsStandard() {
        #expect(SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())).scale == .standard)
    }

    @Test func biggerStepsUpAndStopsAtTheLargest() {
        let zoom = SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make()))
        zoom.bigger()
        #expect(zoom.scale == .large)
        zoom.bigger()
        #expect(zoom.scale == .extraLarge)
        zoom.bigger()
        #expect(zoom.scale == .extraLarge)
    }

    @Test func smallerStepsDownAndStopsAtStandard() {
        let zoom = SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make()))
        zoom.bigger()
        zoom.bigger()
        zoom.smaller()
        #expect(zoom.scale == .large)
        zoom.smaller()
        zoom.smaller()
        #expect(zoom.scale == .standard)
    }

    @Test func resetGoesBackToStandard() {
        let zoom = SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make()))
        zoom.bigger()
        zoom.bigger()
        zoom.reset()
        #expect(zoom.scale == .standard)
    }

    @Test func theSizeIsRemembered() {
        let store = ScratchDefaults.make()
        SidebarZoom(settings: SidebarLayoutSettings(defaults: store)).bigger()
        #expect(SidebarZoom(settings: SidebarLayoutSettings(defaults: store)).scale == .large)
    }

    @Test func aSavedSizeThatIsNoneOfTheThreeReadsAsStandard() {
        let store = ScratchDefaults.make()
        store.set(2.5, forKey: "ShellforgeSidebarScale")
        #expect(SidebarLayoutSettings(defaults: store).scale == .standard)
    }
}
