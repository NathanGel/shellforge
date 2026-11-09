import Foundation
import ShellforgeCore

/// What the app bundle gives the agents: the command that reports an agent's status, the runner
/// that starts an agent with its environment and secrets, and the ready-made agents' folder. Whether
/// macOS runs the app from a temporary copy too, whose paths are gone once it quits.
public struct AgentTools: Sendable, Equatable {
    /// The full path of `shellforge-status`, as an agent's hooks run it.
    public var statusCommand: String?
    /// `shellforge-run`.
    public var runner: URL?
    /// The ready-made agents' files (`AgentRegistry.bundledReadyMade`).
    public var readyMade: URL?
    /// The app runs from an App Translocation copy: no path in it is worth writing into an agent's settings.
    public var translocated: Bool

    public init(statusCommand: String?, runner: URL?, readyMade: URL?, translocated: Bool) {
        self.statusCommand = statusCommand
        self.runner = runner
        self.readyMade = readyMade
        self.translocated = translocated
    }

    /// No tools: a sidebar the app has not handed them to, and tests.
    public static let none = AgentTools(statusCommand: nil, runner: nil, readyMade: nil, translocated: false)

    /// The tools in an app bundle whose resources are at `resourceURL` and which runs from `bundlePath`:
    /// `<resources>/hooks/shellforge-status`, `<resources>/hooks/shellforge-run` and `<resources>/hooks/agents`.
    public static func bundled(resourceURL: URL?, bundlePath: String) -> AgentTools {
        let hooks = resourceURL?.appendingPathComponent("hooks", isDirectory: true)
        return AgentTools(statusCommand: hooks?.appendingPathComponent("shellforge-status").path,
                          runner: hooks?.appendingPathComponent("shellforge-run"),
                          readyMade: AgentRegistry.bundledReadyMade(resourceURL: resourceURL),
                          translocated: BundleLocation.isTranslocated(bundlePath))
    }
}
