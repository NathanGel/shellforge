import Combine
import Foundation

/// Settings › Core › Terminal's switch: whether every terminal draws in Shellforge's colours and
/// iTerm2's Minimal theme. Off until saved on. Each Settings sheet keeps its own unsaved switch;
/// only its Save makes it `isOn`, as with every other Settings card.
@MainActor
public final class TerminalMatchSettings: ObservableObject {
    public nonisolated static let defaultsKey = "ShellforgeMatchTerminal"

    private let defaults: UserDefaults
    @Published public private(set) var isOn: Bool
    /// After a Save that changed `isOn`: the app recolours every terminal.
    public var onChange: (@MainActor (Bool) -> Void)?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.defaultsKey)
    }

    /// A sheet's Save: `on` becomes what every terminal draws in.
    public func save(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        defaults.set(isOn, forKey: Self.defaultsKey)
        onChange?(isOn)
    }

    /// Switches and saves at once, for the app's tests.
    public func set(_ on: Bool) { save(on) }
}
