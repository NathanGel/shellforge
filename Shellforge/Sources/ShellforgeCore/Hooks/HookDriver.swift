// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/HarnessDriver.swift and the state in
// HarnessDiagnostics.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Where an agent's hooks stand, as read off the files Shellforge writes for it.
public enum HookState: Equatable, Sendable {
    case notChecked
    case missing
    case current
    case outdated
    /// Shellforge's own file, in a shape no install writes.
    case invalidOwned
    /// A file Shellforge did not write sits where its own would go.
    case foreign
    case unreadable
    /// This copy of Shellforge cannot install: a translocated bundle, or one without the file.
    case resourceUnavailable
}

/// One agent's hooks — the settings, hooks file, extension or status line Shellforge writes so the
/// agent reports its state — in the one shape `HookIntegrations` drives all four by. A driver is
/// built from what it writes to (`home`, the daemon's port, the bundled file it installs) and reads
/// its files once per probe.
protocol HookDriver: Sendable {
    /// The hooks' state, read off their files, and why they are not current.
    func probe() -> HookProbe
    /// Writes the hooks, or throws `HookInstallError` having written nothing: a file Shellforge
    /// must not replace, or cannot read, stops the whole install before any file is touched.
    func install() throws
}

public struct HookProbe: Equatable, Sendable {
    public var state: HookState
    /// What the sheet says under the agent's name; `nil` when there is nothing to say.
    public var explanation: String?

    /// A state every driver explains the same way.
    init(_ state: HookState) {
        self.state = state
        switch state {
        case .current: explanation = nil
        case .missing: explanation = "Shellforge’s hooks are not installed."
        case .outdated: explanation = "Shellforge’s hooks are out of date."
        case .invalidOwned: explanation = "Shellforge’s hooks are invalid."
        case .foreign: explanation = "A different file occupies the hooks’ path."
        case .unreadable: explanation = "The hooks’ file cannot be read."
        case .resourceUnavailable: explanation = "The bundled hooks are unavailable."
        case .notChecked: explanation = "The hooks were not checked."
        }
    }

    public init(state: HookState, explanation: String?) {
        self.state = state
        self.explanation = explanation
    }

    /// A file at `file`'s path that Shellforge did not write.
    static func foreign(_ file: UserConfigFile) -> HookProbe {
        HookProbe(state: .foreign, explanation: "A different file occupies \(file.displayPath).")
    }

    /// A file that cannot be read, or merged into: `reason` finishes "it …".
    static func refused(_ file: UserConfigFile, _ reason: String) -> HookProbe {
        HookProbe(state: .unreadable, explanation: "\(file.displayPath) \(reason).")
    }
}
