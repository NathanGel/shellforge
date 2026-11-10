import AppKit
import SwiftUI

/// Turns the list it is the background of on or off as AppKit sees it: SwiftUI's `.disabled` stops
/// the rows' own controls but leaves the list's table able to take the keyboard. Off, the table is
/// disabled, so Tab, the arrows, Return and type-select cannot land on a list that is out of sight.
/// The list is the table whose scroll view has this background's frame: the activity bar's table,
/// in the same host, is left alone.
struct ListKeyboardGate: NSViewRepresentable {
    let enabled: Bool

    final class Gate: NSView {
        var enabled = true { didSet { if enabled != oldValue { apply() } } }
        private weak var found: NSTableView?

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func layout() { super.layout(); apply() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func apply() {
            guard let table = found ?? list() else { return }
            found = table
            if table.isEnabled != enabled { table.isEnabled = enabled }
        }

        /// The table under the sidebar's host whose scroll view lies where this view does.
        private func list() -> NSTableView? {
            guard window != nil else { return nil }
            let here = convert(bounds, to: nil)
            // Up to the sidebar's own host, or the top of the window when there is none.
            var host: NSView = self
            while !(host is RowHighlightBoundary), let parent = host.superview { host = parent }
            func tables(in view: NSView) -> [NSTableView] {
                if let table = view as? NSTableView { return [table] }
                return view.subviews.flatMap { tables(in: $0) }
            }
            return tables(in: host).first { table in
                guard let scroll = table.enclosingScrollView else { return false }
                let there = scroll.convert(scroll.bounds, to: nil)
                return abs(there.minX - here.minX) < 1 && abs(there.width - here.width) < 1
                    && abs(there.minY - here.minY) < 1 && abs(there.height - here.height) < 1
            }
        }
    }

    func makeNSView(context: Context) -> Gate {
        let gate = Gate(frame: .zero)
        gate.setAccessibilityElement(false)
        return gate
    }

    func updateNSView(_ gate: Gate, context: Context) { gate.enabled = enabled }
}
