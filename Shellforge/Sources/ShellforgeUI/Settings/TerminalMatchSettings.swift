import Combine
import Foundation

/// Settings › Core › Terminal's switch: whether every terminal draws in Shellforge's colours and
/// iTerm2's Minimal theme. Off until saved on. `draft` is the switch while the panel is open;
/// only Save makes it `isOn`, as with every other Settings card.
@MainActor
public final class TerminalMatchSettings: ObservableObject {
    public static let defaultsKey = "ShellforgeMatchTerminal"

    private let defaults: UserDefaults
    public private(set) var isOn: Bool
    @Published public var draft: Bool
    /// After a Save that changed `isOn`: the app recolours every terminal.
    public var onChange: (@MainActor (Bool) -> Void)?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.defaultsKey)
        draft = isOn
    }

    /// The panel opens: the switch shows what is saved.
    public func beginEditing() { draft = isOn }

    /// Save: `draft` becomes what every terminal draws in.
    public func save() {
        guard draft != isOn else { return }
        isOn = draft
        defaults.set(isOn, forKey: Self.defaultsKey)
        onChange?(isOn)
    }

    /// Switches and saves at once, for the app's tests.
    public func set(_ on: Bool) {
        draft = on
        save()
    }
}
