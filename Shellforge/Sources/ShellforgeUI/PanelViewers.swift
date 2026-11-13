import SwiftUI

/// How many windows show an app-wide panel (Files, Git). Each window's panel registers when it
/// appears and lets go when it disappears or its window closes; `changed` hears whether any shows,
/// each time that flips.
@MainActor
final class PanelViewers {
    private(set) var count = 0
    private let changed: @MainActor (_ shown: Bool) -> Void

    init(_ changed: @escaping @MainActor (_ shown: Bool) -> Void) { self.changed = changed }

    /// One more window shows the panel, until the viewer returned is released or goes.
    func register() -> PanelViewer {
        count += 1
        if count == 1 { changed(true) }
        return PanelViewer { [weak self] in self?.unregister() }
    }

    private func unregister() {
        guard count > 0 else { return }
        count -= 1
        if count == 0 { changed(false) }
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
