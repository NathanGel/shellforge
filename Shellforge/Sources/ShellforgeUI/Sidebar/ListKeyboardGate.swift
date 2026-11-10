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
            // A table found in another window — the view moved — is not this window's list.
            let cached = found.flatMap { $0.window != nil && $0.window === window ? $0 : nil }
            guard let table = cached ?? list() else { return }
            found = table
            guard table.isEnabled != enabled else { return }
            table.isEnabled = enabled
            // Back in sight: the sidebar's host may give the list the keyboard it took away.
            guard enabled else { return }
            var ancestor = superview
            while let view = ancestor, !(view is ListKeyboardHome) { ancestor = view.superview }
            (ancestor as? ListKeyboardHome)?.listTakesKeyboardAgain()
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

/// The view holding the keyboard while the list is out of sight: told when the list can take it again.
@MainActor
protocol ListKeyboardHome: AnyObject {
    func listTakesKeyboardAgain()
}
