import AppKit
import ShellforgeDesign
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeUI

/// Settings › Core › Theme: its settings are switches as System Settings draws them, and its pickers
/// follow Follow Mac Appearance.
@MainActor @Suite struct ThemeCardTests {
    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.compactMap { $0 as? T } + view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func host(_ choice: ThemeChoice) -> (NSHostingView<ThemeCard>, NSWindow) {
        let host = NSHostingView(rootView: ThemeCard(choice: .constant(choice), matchesTerminal: .constant(false)))
        host.frame.size = NSSize(width: 500, height: host.fittingSize.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    @Test func theSettingsAreSwitchesNotCheckboxes() {
        let (host, window) = host(ThemeChoice())
        defer { window.close() }
        #expect(descendants(of: NSSwitch.self, in: host).count == 2, "Follow Mac Appearance and Match Terminal")
        #expect(descendants(of: NSButton.self, in: host).allSatisfy { $0 is NSPopUpButton }, "no checkbox beside them")
    }

    @Test func followingTheMacOffersALightAndADarkTheme() {
        let (host, window) = host(ThemeChoice(followsMac: true))
        defer { window.close() }
        #expect(descendants(of: NSPopUpButton.self, in: host).count == 2)
    }

    @Test func notFollowingTheMacOffersOneTheme() {
        let (host, window) = host(ThemeChoice(followsMac: false, single: "dracula"))
        defer { window.close() }
        let pickers = descendants(of: NSPopUpButton.self, in: host)
        #expect(pickers.count == 1)
        #expect(pickers.first?.titleOfSelectedItem == "Dracula")
        #expect(pickers.first?.itemTitles == ThemeCatalog.all.map(\.name))
    }
}
