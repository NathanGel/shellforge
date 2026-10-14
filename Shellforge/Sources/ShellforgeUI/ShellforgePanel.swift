import AppKit
import SwiftUI

/// A sheet in a panel of its own, on its parent window, in that window's appearance.
@MainActor
public enum ShellforgePanel {
    /// Shows `view` as a sheet on `parent`, or on its own when there is no parent window.
    @discardableResult
    public static func present(_ view: some View, over parent: NSWindow?) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        if let parent { parent.beginSheet(panel) } else { panel.center(); panel.makeKeyAndOrderFront(nil) }
        return panel
    }

    public static func dismiss(_ panel: NSWindow) {
        if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.orderOut(nil) }
    }
}

/// The one sheet a sidebar shows at a time. It holds the panel while it is up and lets it go on
/// dismissal; the view's dismiss reaches back weakly, so a closed sheet frees what it drew.
@MainActor
public final class PanelSlot {
    public private(set) var panel: NSPanel?

    public init() {}

    /// Presents the view `make` builds — handed the dismiss to call — unless a sheet is already up,
    /// in which case that one is returned.
    @discardableResult
    public func present<V: View>(over parent: NSWindow?, _ make: (@escaping @MainActor () -> Void) -> V) -> NSPanel {
        if let panel { return panel }
        let shown = ShellforgePanel.present(make { [weak self] in self?.dismiss() }, over: parent)
        panel = shown
        return shown
    }

    public func dismiss() {
        guard let shown = panel else { return }
        panel = nil
        ShellforgePanel.dismiss(shown)
        shown.contentView = nil
    }
}

/// Folder choosing for Add Project, in the app's appearance.
@MainActor
public enum FolderChooser {
    public static func panel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Project"
        return panel
    }

    /// The folder the user picked, or nil when they cancelled.
    public static func choose() -> String? {
        let panel = panel()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// The window a SwiftUI view is drawn in, for presenting a `ShellforgePanel` from it.
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
