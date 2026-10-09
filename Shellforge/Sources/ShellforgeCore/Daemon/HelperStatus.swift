import Foundation

/// How far the chain to the helper reaches: the sidebar shows `text` while `isProblem`. A running
/// helper is not a connected one, so process, socket and version are told apart.
public enum HelperStatus: Equatable, Sendable {
    case starting
    /// The app was built without the daemon's package.
    case helperMissing
    case pythonMissing
    /// The helper has exited more than once; the message is its last exit.
    case helperFailing(String)
    /// The helper answers in a protocol this app cannot read.
    case helperMismatch
    /// The helper process is up but its socket is not answering.
    case helperUnreachable
    case connected

    public var text: String {
        switch self {
        case .starting: "Starting Shellforge’s helper…"
        case .helperMissing: "Shellforge’s helper is missing from the app; reinstall Shellforge."
        case .pythonMissing: "Shellforge needs Python 3.11 or newer on your login shell’s PATH."
        case .helperFailing(let message): "Shellforge’s helper keeps stopping (\(message)). Its log is in ~/Library/Application Support/Shellforge/shellforged.log."
        case .helperMismatch: "Shellforge’s helper is from another version; quit Shellforge and open it again."
        case .helperUnreachable: "Reconnecting to Shellforge’s helper…"
        case .connected: "Connected"
        }
    }

    public var isProblem: Bool { self != .starting && self != .connected }
}
