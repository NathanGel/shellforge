import Foundation
import AppKit
import os
import SwiftUI

private let themeLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "theme")

/// The theme Shellforge draws in, read by every `Palette` token and the terminal palette each time
/// they resolve. Thread-safe: a colour resolves wherever AppKit draws it, so reading never waits on
/// the main actor. Shellforge until someone sets another.
public enum ThemeRuntime {
    /// Posted on the main thread when the theme changes — not when it is set to the one it already
    /// is. `.themed()` redraws on it.
    public static let didChange = Notification.Name("ShellforgeThemeDidChange")

    /// The one store the app uses. Tests make their own, so setting a theme there never recolours
    /// another test's tokens.
    static let shared = ThemeStore()

    /// A theme for the current task only, overriding the shared one: lets a test resolve the tokens
    /// in a theme without touching what every other test reads.
    @TaskLocal static var override: Theme?

    public static var current: Theme { override ?? shared.current }

    public static func set(_ theme: Theme) { shared.set(theme) }
}

/// A theme behind a lock, and the notice that it changed.
final class ThemeStore: Sendable {
    private let theme = OSAllocatedUnfairLock(initialState: ThemeCatalog.shellforge)

    var current: Theme { theme.withLock { $0 } }

    /// Sets `newTheme` and, when it differs from the current one, posts `ThemeRuntime.didChange`
    /// on the main thread — at once when called there, otherwise on its next turn.
    func set(_ newTheme: Theme) {
        let changed = theme.withLock { current in
            guard current != newTheme else { return false }
            current = newTheme
            return true
        }
        guard changed else { return }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async { self.post() }
        }
    }

    private func post() {
        NotificationCenter.default.post(name: ThemeRuntime.didChange, object: self)
    }
}

extension View {
    /// Redraws this view's content in the new theme when the theme changes, keeping its identity:
    /// its state — scroll position, open rows, a half-typed field — survives the change.
    public func themed() -> some View {
        background(ThemeRedraw().allowsHitTesting(false))
    }
}

/// `.themed()`'s probe: an AppKit view inside the SwiftUI root that, on `ThemeRuntime.didChange` —
/// or a new accent colour or Increase Contrast, which change no appearance either — makes the root
/// resolve its colours again.
struct ThemeRedraw: NSViewRepresentable {
    func makeNSView(context: Context) -> ThemeRedrawView { ThemeRedrawView() }
    func updateNSView(_ nsView: ThemeRedrawView, context: Context) {}
}

/// SwiftUI keeps a dynamic colour as it resolved it until the appearance it was drawn in changes:
/// a new environment value, a fresh body or a redraw all leave it be. So on a theme change this
/// flips its hosting view to the other appearance, lays it out — SwiftUI resolves every colour
/// there — and puts the appearance back, when SwiftUI resolves them again in the new theme. All in
/// one turn of the run loop, so nothing is drawn on screen in the other appearance; the views keep
/// their identity, so no state is lost.
final class ThemeRedrawView: NSView {
    /// Said once, not per probe or per change: `.themed()` found no SwiftUI root to redraw.
    private static var reportedNoHost = false
    /// A theme change came while this probe was out of its window, so its root has not resolved
    /// the new colours yet: done when it is back in one.
    private var redrawPending = false

    /// How many times this probe made its root resolve its colours again, for the tests.
    private(set) var redraws = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        observe()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observe()
    }

    /// The theme, and what changes a system colour without changing the appearance: the accent
    /// colour and Increase Contrast. Every token is a dynamic colour now, even under Shellforge, so
    /// SwiftUI would keep each as it resolved it until the appearance changes.
    private func observe() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(themeDidChange), name: ThemeRuntime.didChange, object: nil)
        center.addObserver(self, selector: #selector(themeDidChange), name: NSColor.systemColorsDidChangeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(themeDidChange),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    /// Never a click's target: the probe fills the whole root, behind it, and a click in the root's
    /// empty space is the root's own — never the start of a window drag.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func themeDidChange(_ notification: Notification) {
        guard window != nil else {
            redrawPending = true
            return
        }
        redraw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard redrawPending, window != nil else { return }
        redrawPending = false
        redraw()
    }

    private func redraw() {
        guard let host = hostingView else {
            if !Self.reportedNoHost {
                Self.reportedNoHost = true
                themeLog.debug(".themed() found no NSHostingView above it; its colours keep the old theme")
            }
            return
        }
        redraws += 1
        let kept = host.appearance
        let isDark = host.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        host.appearance = NSAppearance(named: isDark ? .aqua : .darkAqua)
        host.layoutSubtreeIfNeeded()
        host.appearance = kept
    }

    /// The SwiftUI root this probe sits in: the outermost ancestor that is an `NSHostingView`, so a
    /// probe below an inner host (a cell's, a representable's) still redraws the whole root. Read by
    /// class name because its generic content type is not known here.
    private var hostingView: NSView? {
        var found: NSView?
        var view = superview
        while let candidate = view {
            var cls: AnyClass? = type(of: candidate)
            while let current = cls {
                if NSStringFromClass(current).contains("NSHostingView") {
                    found = candidate
                    break
                }
                cls = class_getSuperclass(current)
            }
            view = candidate.superview
        }
        return found
    }
}

/// The theme's accent as the tint of controls under it, only while a theme with colours of its
/// own is on: under Shellforge the system's own tint is kept, so controls grey in an inactive
/// window exactly as they always have.
private struct ThemeTint: ViewModifier {
    @State private var themed = ThemeRuntime.current.colors != nil

    func body(content: Content) -> some View {
        content
            .tint(themed ? Palette.accent : nil)
            .onReceive(NotificationCenter.default.publisher(for: ThemeRuntime.didChange)) { _ in
                themed = ThemeRuntime.current.colors != nil
            }
    }
}

extension View {
    /// Tints controls with the theme's accent while a non-Shellforge theme is on; see `ThemeTint`.
    public func themeTint() -> some View { modifier(ThemeTint()) }
}
