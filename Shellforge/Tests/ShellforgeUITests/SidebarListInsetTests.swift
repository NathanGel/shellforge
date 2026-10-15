import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
import ShellforgeDesign
@testable import ShellforgeUI

/// What sits outside the sidebar's `List` — the footer card, the pinned header — lines up with the
/// rows by the list's own inset, which the system sets: measured here from a real sidebar list.
@MainActor @Suite struct SidebarListInsetTests {
    @Test func theListInsetIsTheOneASidebarListDraws() throws {
        let list = List { Color.white.frame(height: 10) }.listStyle(.sidebar).scrollContentBackground(.hidden)
            .frame(width: 300, height: 60).background(Color.black)
        let host = NSHostingView(rootView: list)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame.size = NSSize(width: 300, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        let rep = try #require(Snapshot.bitmap(of: host))
        let row = (0..<rep.pixelsHigh).first { y in (rep.colorAt(x: rep.pixelsWide / 2, y: y)?.brightnessComponent ?? 0) > 0.9 }
        let y = try #require(row, "the row is drawn")
        let first = (0..<rep.pixelsWide).first { x in (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0) > 0.9 }
        let leading = CGFloat(try #require(first)) / Snapshot.scale
        #expect(abs(leading - SidebarRowLayout.listInset) <= 1, "a sidebar list insets its rows by \(leading) pt")
    }
}
