import Foundation
import Testing
@testable import ShellforgeDesign
@testable import ShellforgeUI

/// The sidebar's width, dragged to size, and whether it is hidden: remembered, and kept within
/// what the window and the terminal need. Each test has a defaults suite of its own.
@Suite struct SidebarLayoutSettingsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "shellforge-layout-\(UUID().uuidString)")!
    }

    @Test func aNewSettingsReadsTheDefaults() {
        let settings = SidebarLayoutSettings(defaults: defaults())
        #expect(settings.width == Size.sidebarWidth)
        #expect(!settings.hidden)
    }

    @Test func theWidthIsRememberedAndClamped() {
        let store = defaults()
        var settings = SidebarLayoutSettings(defaults: store)
        settings.width = 500
        #expect(SidebarLayoutSettings(defaults: store).width == 500)
        settings.width = 10
        #expect(settings.width == Size.sidebarMinWidth)
        settings.width = 5_000
        #expect(SidebarLayoutSettings(defaults: store).width == SidebarLayoutSettings.maxWidth)
    }

    @Test func hiddenIsRemembered() {
        let store = defaults()
        var settings = SidebarLayoutSettings(defaults: store)
        settings.hidden = true
        #expect(SidebarLayoutSettings(defaults: store).hidden)
    }

    @Test func theWidthIsClampedToTheWindow() {
        #expect(SidebarLayoutSettings.width(500, windowWidth: 2_000) == 500)
        #expect(SidebarLayoutSettings.width(500, windowWidth: 700) == 700 - SidebarLayoutSettings.terminalMinWidth,
                "the terminal keeps its minimum; the sidebar gives way")
        #expect(SidebarLayoutSettings.width(500, windowWidth: 500) == Size.sidebarMinWidth,
                "under 680 pt the sidebar keeps its minimum and the terminal has what is left")
        #expect(SidebarLayoutSettings.width(500, windowWidth: 200) == 0, "a window too narrow for both: the terminal")
    }

    /// A window's preferred width is its own: dragged from what it was, kept within the limits —
    /// never from the width a narrow window happened to give it.
    @Test func aDragMovesThePreferredWidth() {
        #expect(SidebarLayoutSettings.dragged(700, by: -5) == 695)
        #expect(SidebarLayoutSettings.dragged(700, by: 500) == SidebarLayoutSettings.maxWidth)
        #expect(SidebarLayoutSettings.dragged(400, by: -500) == Size.sidebarMinWidth)
    }
}
