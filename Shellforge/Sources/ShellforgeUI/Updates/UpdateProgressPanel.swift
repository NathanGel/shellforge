// Ported from AiTerm (app/Sources/AiTerm/UpdateProgressPanel.swift), GPLv3, Laurens D'Hondt.
import AppKit
import ShellforgeDesign

/// The small "Downloading Shellforge 0.3.0…" window shown while an update downloads and is
/// verified — the alert itself cannot show progress. Stock AppKit controls; spacing from `Space`.
@MainActor
enum UpdateProgressPanel {
    /// Shows the panel and returns the call that closes it.
    static func show(_ text: String) -> () -> Void {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, NSTextField(labelWithString: text)])
        stack.orientation = .horizontal; stack.spacing = Space.base
        stack.edgeInsets = NSEdgeInsets(top: Space.block, left: Space.block, bottom: Space.block, right: Space.block)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: stack.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Shellforge"
        panel.isReleasedWhenClosed = false
        panel.contentView = stack
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return { panel.close() }
    }
}
