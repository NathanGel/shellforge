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
        #expect(SidebarLayoutSettings.width(500, windowWidth: 500) == 0,
                "under 680 pt both minimums do not fit: the terminal keeps its own, and the sidebar steps aside")
        #expect(SidebarLayoutSettings.width(500, windowWidth: 680) == Size.sidebarMinWidth)
        #expect(SidebarLayoutSettings.width(500, windowWidth: 200) == 0, "a window too narrow for both: the terminal")
    }

    /// The toolbelt on the right takes its width from the terminal's, not the sidebar's room.
    @Test func theToolbeltCountsAgainstTheTerminal() {
        #expect(SidebarLayoutSettings.width(500, windowWidth: 1_000, beside: 300) == 1_000 - 300 - SidebarLayoutSettings.terminalMinWidth)
        #expect(SidebarLayoutSettings.width(500, windowWidth: 800, beside: 300) == 0, "no room for both minimums")
        #expect(SidebarLayoutSettings.width(500, windowWidth: 2_000, beside: 0) == 500)
    }

    /// Dragged narrower, a window stops where the sidebar at its minimum and the terminal at its own
    /// both still fit: below it the sidebar would jump from 360 pt to nothing (680 pt, more with the
    /// toolbelt).
    @Test func aWindowStopsBeforeTheSidebarWouldJump() {
        let minimum = SidebarLayoutSettings.minimumWindowWidth(beside: 0)
        #expect(minimum == Size.sidebarMinWidth + SidebarLayoutSettings.terminalMinWidth)
        #expect(SidebarLayoutSettings.width(500, windowWidth: minimum) == Size.sidebarMinWidth, "at the minimum the sidebar still shows")
        #expect(SidebarLayoutSettings.width(500, windowWidth: minimum - 1) == 0, "one point less and it would jump")
        #expect(SidebarLayoutSettings.minimumWindowWidth(beside: 250) == minimum + 250)
    }

    /// iTerm2 holds the toolbelt to at most half the window: a 1000 pt toolbelt in a 1360 pt
    /// window is 680 pt, so the window stops at 1360 pt, not 1680 pt.
    @Test func aWideToolbeltCountsAsLayoutWillMakeIt() {
        let base = SidebarLayoutSettings.minimumWindowWidth(beside: 0)
        #expect(SidebarLayoutSettings.minimumWindowWidth(beside: 1000, toolbeltMaxFraction: 0.5) == base * 2)
        #expect(SidebarLayoutSettings.minimumWindowWidth(beside: 250, toolbeltMaxFraction: 0.5) == base + 250, "within half: as it is")
    }

    /// The drag handle straddles the sidebar's border, mostly outside it: the list's scroller, at
    /// the sidebar's right edge, stays clickable.
    @Test func theHandleSitsOnTheBorderClearOfTheScroller() {
        let handle = SidebarLayoutSettings.dragHandle(edge: 260)
        #expect(handle.x < 260 && handle.x + handle.width > 260, "on the border")
        #expect(260 - handle.x <= 1, "no more than the hairline inside the sidebar")
        #expect(handle.width >= 3, "as wide as the left tab bar's handle")
    }

    /// A window's preferred width is its own: dragged from what it was, kept within the limits —
    /// never from the width a narrow window happened to give it.
    @Test func aDragMovesThePreferredWidth() {
        #expect(SidebarLayoutSettings.dragged(700, by: -5) == 695)
        #expect(SidebarLayoutSettings.dragged(700, by: 500) == SidebarLayoutSettings.maxWidth)
        #expect(SidebarLayoutSettings.dragged(400, by: -500) == Size.sidebarMinWidth)
    }
}
