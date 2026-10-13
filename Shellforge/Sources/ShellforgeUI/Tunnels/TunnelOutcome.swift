import Foundation

/// What became of one tunnel call to the helper: its tunnel, and the error a refusal is said with,
/// or nil when it worked.
public struct TunnelOutcome: Equatable, Sendable {
    public let alias: String
    public let error: String?

    public init(alias: String, error: String?) {
        self.alias = alias
        self.error = error
    }
}
