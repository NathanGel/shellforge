import Foundation

/// One of a project's tunnels, as Shellforge keeps it: the `Host` alias it runs and when it starts
/// by itself. Its forwards are the config's, read when shown, never copied.
public struct TunnelDefinition: Codable, Equatable, Sendable, Identifiable {
    public enum AutoStart: String, Codable, Sendable, CaseIterable {
        case never, onLaunch, onTaskOpen
    }

    public var alias: String
    public var autoStart: AutoStart
    public var id: String { alias }

    public init(alias: String, autoStart: AutoStart = .never) { self.alias = alias; self.autoStart = autoStart }

    /// The variable a task's shell reads a running tunnel's port from: `SHELLFORGE_TUNNEL_<NAME>_PORT`,
    /// the alias upper-cased with every character but a letter or digit made `_`.
    public static func environmentName(alias: String) -> String {
        let name = String(alias.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return "SHELLFORGE_TUNNEL_\(name)_PORT"
    }
}
