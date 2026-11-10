import AppKit
import SwiftUI

/// An empty, unclickable AppKit view carrying `name` as its identifier: where a SwiftUI part of
/// the sidebar is in the window, for a test to find (SwiftUI's own views are out of AppKit's sight,
/// and a test host builds no accessibility tree).
struct ViewMark: NSViewRepresentable {
    let name: String

    final class Mark: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Mark {
        let mark = Mark(frame: .zero)
        mark.identifier = NSUserInterfaceItemIdentifier(name)
        mark.setAccessibilityElement(false)
        return mark
    }

    func updateNSView(_ view: Mark, context: Context) {}
}
