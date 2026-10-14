import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeUI

/// Settings › Core › Terminal is one row, its setting a trailing switch as System Settings draws one.
@MainActor @Suite struct TerminalMatchCardTests {
    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.compactMap { $0 as? T } + view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    @Test func theSettingIsASwitchNotACheckbox() {
        let host = NSHostingView(rootView: TerminalMatchCard(settings: TerminalMatchSettings(defaults: ScratchDefaults.make())))
        host.frame.size = NSSize(width: 500, height: host.fittingSize.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        #expect(descendants(of: NSSwitch.self, in: host).count == 1)
        #expect(descendants(of: NSButton.self, in: host).isEmpty, "no checkbox beside it")
    }
}
