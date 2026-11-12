import Combine
import Foundation
import ShellforgeDesign

/// Settings › Core › Theme: which theme Shellforge draws in — one for a light Mac and one for a dark
/// Mac while following the Mac, otherwise one for both. Shellforge everywhere until saved otherwise.
/// Each Settings sheet keeps its own unsaved choice; only its Save makes it `choice`. Synced keys, no
/// NoSync prefix: a theme is a setting, and names no private data.
@MainActor
public final class ThemeSettings: ObservableObject {
    public nonisolated static let followsMacKey = "ShellforgeThemeFollowsMac"
    public nonisolated static let lightKey = "ShellforgeThemeLight"
    public nonisolated static let darkKey = "ShellforgeThemeDark"
    public nonisolated static let singleKey = "ShellforgeTheme"

    private let defaults: UserDefaults
    @Published public private(set) var choice: ThemeChoice
    /// After a Save that changed `choice`: the app applies it.
    public var onChange: (() -> Void)?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        let shellforge = ThemeCatalog.shellforge.id
        choice = ThemeChoice(followsMac: defaults.object(forKey: Self.followsMacKey) as? Bool ?? true,
                             light: defaults.string(forKey: Self.lightKey) ?? shellforge,
                             dark: defaults.string(forKey: Self.darkKey) ?? shellforge,
                             single: defaults.string(forKey: Self.singleKey) ?? shellforge)
    }

    /// A sheet's Save, or the gear menu's pick: `newChoice` becomes the one Shellforge draws in.
    public func save(_ newChoice: ThemeChoice) {
        guard newChoice != choice else { return }
        choice = newChoice
        defaults.set(newChoice.followsMac, forKey: Self.followsMacKey)
        defaults.set(newChoice.light, forKey: Self.lightKey)
        defaults.set(newChoice.dark, forKey: Self.darkKey)
        defaults.set(newChoice.single, forKey: Self.singleKey)
        onChange?()
    }
}

extension ThemeChoice {
    /// This choice with the fields a sheet changed — each of `draft`'s that differs from `opened`,
    /// what was saved when the sheet opened — and every other field kept as it is now: a pick made
    /// from a gear menu while the sheet was open survives the sheet's Save, field by field.
    public func merging(_ draft: ThemeChoice, openedWith opened: ThemeChoice) -> ThemeChoice {
        var merged = self
        if draft.followsMac != opened.followsMac { merged.followsMac = draft.followsMac }
        if draft.light != opened.light { merged.light = draft.light }
        if draft.dark != opened.dark { merged.dark = draft.dark }
        if draft.single != opened.single { merged.single = draft.single }
        return merged
    }
}
