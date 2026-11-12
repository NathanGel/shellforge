import Foundation
import os
import SwiftUI

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
    /// Redraws this view's content when the theme changes, so every `Palette` colour in it resolves
    /// again in the new theme. The content is rebuilt, so state inside it starts over.
    public func themed() -> some View {
        modifier(ThemedContent())
    }
}

/// `.themed()`: a counter the content takes as its identity, bumped on `ThemeRuntime.didChange`.
/// SwiftUI keeps a resolved colour until something it depends on changes; a new identity is the
/// one change that reaches every colour below.
struct ThemedContent: ViewModifier {
    @State private var version = 0

    func body(content: Content) -> some View {
        content
            .id(version)
            .onReceive(NotificationCenter.default.publisher(for: ThemeRuntime.didChange)) { _ in version += 1 }
    }
}
