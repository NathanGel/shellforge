import SwiftUI

/// Whether any window shows an app-wide panel (Files, Git). Each window's panel registers when it
/// appears and lets go when it disappears or its window closes. A panel whose view is up can still
/// be out of sight — its sidebar hidden (⌃⌘S), its window in the Dock or covered — which SwiftUI
/// does not say: the host tells `visible`, whether a sidebar that can be seen has the panel
/// selected. The panel shows while both hold; `changed` hears each time that flips.
@MainActor
final class PanelViewers {
    private(set) var count = 0
    /// The host's word: some sidebar that can be seen has the panel selected. True until it says.
    private(set) var visible = true
    private var shown = false
    private let changed: @MainActor (_ shown: Bool) -> Void

    init(_ changed: @escaping @MainActor (_ shown: Bool) -> Void) { self.changed = changed }

    /// One more window shows the panel, until the viewer returned is released or goes.
    func register() -> PanelViewer {
        count += 1
        settle()
        return PanelViewer { [weak self] in self?.unregister() }
    }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        settle()
    }

    private func unregister() {
        guard count > 0 else { return }
        count -= 1
        settle()
    }

    private func settle() {
        let now = count > 0 && visible
        guard now != shown else { return }
        shown = now
        changed(now)
    }
}

/// One window's showing of a panel. Released once: by `release()`, or when it goes (the window's
/// view closed without saying it disappeared).
final class PanelViewer: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (@MainActor @Sendable () -> Void)?

    init(_ onRelease: @escaping @MainActor @Sendable () -> Void) { self.onRelease = onRelease }

    @MainActor func release() {
        take()?()
    }

    private func take() -> (@MainActor @Sendable () -> Void)? {
        lock.withLock {
            defer { onRelease = nil }
            return onRelease
        }
    }

    deinit {
        guard let release = take() else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { release() }
        } else {
            let main: @Sendable () -> Void = { MainActor.assumeIsolated { release() } }
            DispatchQueue.main.async(execute: main)
        }
    }
}

/// Registers the view's window as showing a panel while the view is on screen.
struct PanelViewing: ViewModifier {
    let register: @MainActor () -> PanelViewer
    @State private var viewer: PanelViewer?

    func body(content: Content) -> some View {
        content
            .onAppear { if viewer == nil { viewer = register() } }
            .onDisappear {
                viewer?.release()
                viewer = nil
            }
    }
}
