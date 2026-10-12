import Foundation

/// One of a project's tunnels, as Shellforge keeps it: the `Host` alias it runs and when it starts
/// by itself. Its forwards are the config's, read when shown, never copied.
public struct TunnelDefinition: Codable, Equatable, Sendable, Identifiable {
    public enum AutoStart: String, Codable, Sendable, CaseIterable {
        case never, onLaunch, onTaskOpen
    }

    public var alias: String
    public var autoStart: AutoStart
    /// Left running when Shellforge quits; the next launch adopts it.
    public var keepRunning: Bool
    public var id: String { alias }

    public init(alias: String, autoStart: AutoStart = .never, keepRunning: Bool = false) {
        self.alias = alias; self.autoStart = autoStart; self.keepRunning = keepRunning
    }

    private enum CodingKeys: String, CodingKey { case alias, autoStart, keepRunning }

    /// A project saved before keep-running existed decodes with it off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alias = try c.decode(String.self, forKey: .alias)
        autoStart = try c.decode(AutoStart.self, forKey: .autoStart)
        keepRunning = try c.decodeIfPresent(Bool.self, forKey: .keepRunning) ?? false
    }

    /// The variable a task's shell reads a running tunnel's port from: `SHELLFORGE_TUNNEL_<NAME>_PORT`,
    /// the alias upper-cased with every character but a letter or digit made `_`.
    public static func environmentName(alias: String) -> String {
        let name = String(alias.uppercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        return "SHELLFORGE_TUNNEL_\(name)_PORT"
    }
}
