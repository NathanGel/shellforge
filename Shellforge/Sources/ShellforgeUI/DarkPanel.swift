import AppKit
import SwiftUI

/// A sheet in a panel of its own, dark like the sidebar. SwiftUI's `.sheet` would hang a sheet from
/// iTerm2's window in that window's appearance; this one keeps AiTerm's, and leaves iTerm2's alone.
@MainActor
public enum DarkPanel {
    /// Shows `view` as a sheet on `parent`, or on its own when there is no parent window.
    @discardableResult
    public static func present(_ view: some View, over parent: NSWindow?) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let parent { parent.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
        return panel
    }

    public static func dismiss(_ panel: NSWindow) {
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
    }
}

/// The window a SwiftUI view is drawn in, for presenting a `DarkPanel` from it.
final class WindowAnchor {
    weak var window: NSWindow?
}

/// Records the window of the view it sits behind into `anchor`.
struct WindowReader: NSViewRepresentable {
    let anchor: WindowAnchor

    final class Probe: NSView {
        var anchor: WindowAnchor?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); anchor?.window = window }
    }

    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.anchor = anchor; return probe }
    func updateNSView(_ view: Probe, context: Context) { view.anchor = anchor; anchor.window = view.window }
}
