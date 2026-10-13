// Ported from AiTerm (app/Sources/AiTermCore/Daemon/DaemonProtocol.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The app's half of the wire contract with the daemon (`daemon/shellforged/protocol.py`): its
/// protocol version, its frame limit, and every request, event and error code it names. Each is
/// checked against the daemon's own by `WireContractTests`, which reads the manifest the daemon's
/// test suite writes beside its golden frames in `Shellforge/daemon/tests/wire/`.
public enum DaemonProtocol {
    /// The version `workspace.snapshot` reports. A helper that reports another is one this app
    /// cannot speak (`DaemonError.Code.incompatible`).
    public static let version = 2
    /// The longest line either side reads: the daemon's request reader is limited to it, and a
    /// longer line from the daemon ends this app's connection.
    public static let maximumFrameBytes = 1 << 20
}

/// A request the daemon answers. Only those Shellforge sends: the daemon also serves the iTerm2
/// bridge's (`--session-source iterm`), which the app never uses.
public enum DaemonMethod: String, CaseIterable, Sendable {
    case workspaceSnapshot = "workspace.snapshot"
    /// Not sent by the app: `shellforged ctl`'s.
    case sessionsList = "sessions.list"
    case sessionsMarkSeen = "sessions.markSeen"
    /// The app's tabs, replacing the daemon's last list.
    case sessionsUpdate = "sessions.update"
    /// Also this client's liveness check (`DaemonClient.livenessCheck`): it exists in app mode and costs nothing.
    case usageGet = "usage.get"
    /// A project's SSH tunnel, started with the app's login environment, or stopped.
    case tunnelsStart = "tunnels.start"
    case tunnelsStop = "tunnels.stop"
    /// Not sent by the app, which has every tunnel from the snapshot and `tunnel.changed`.
    case tunnelsList = "tunnels.list"
    case tunnelsHold = "tunnels.hold"
}

/// An event the daemon broadcasts that Shellforge reads. Any other name — the iTerm2 bridge's, or a
/// newer helper's — arrives as `DaemonEvent.unknown`; one among these that cannot be read ends the
/// connection (`DaemonClient`).
public enum DaemonEventName: String, CaseIterable, Sendable {
    case sessionOpened = "session.opened"
    case sessionChanged = "session.changed"
    case sessionClosed = "session.closed"
    case usageChanged = "usage.changed"
    case tunnelChanged = "tunnel.changed"
}

extension DaemonError {
    /// What went wrong, by name: one of the daemon's (`daemonCodes`), which arrive in an error reply,
    /// or one of this client's own. Any other name a helper sends is kept as it came.
    public struct Code: RawRepresentable, Hashable, Sendable, Decodable, ExpressibleByStringLiteral, CustomStringConvertible {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public var description: String { rawValue }

        // The daemon's.
        /// A request's parameters are missing or of the wrong type.
        public static let badParams: Code = "bad_params"
        /// The thing a request named — a window, session or task — is already gone.
        public static let notFound: Code = "not_found"
        /// The daemon has no connection to iTerm2, or lost it during the request.
        public static let itermUnavailable: Code = "iterm_unavailable"
        /// A line that is not a request at all. This client also uses it for a request too long to send.
        public static let `protocol`: Code = "protocol"
        /// The handler failed in a way it did not name.
        public static let `internal`: Code = "internal"
        /// The daemon has no handler for this request name — an older helper out of sync with a newer app.
        public static let unknownMethod: Code = "unknown_method"
        /// Every code the daemon answers with.
        public static let daemonCodes: [Code] = [.badParams, .notFound, .itermUnavailable, .protocol, .internal, .unknownMethod]

        // This client's own.
        /// `DaemonClient.snapshot()`'s guard: a helper whose protocol version this app cannot speak.
        public static let incompatible: Code = "incompatible"
        /// No reply within the request's timeout; what the request asked for may still happen.
        public static let timeout: Code = "timeout"
        /// The connection closed, or was never open, before the reply came.
        public static let disconnected: Code = "disconnected"
        /// A `DaemonClient` is single-use: one that has connected once cannot connect again.
        public static let connectionUsed: Code = "connection_used"
        /// The socket could not be made, or its path is too long.
        public static let socket: Code = "socket"
        /// The daemon's socket did not accept the connection.
        public static let connect: Code = "connect"
        /// The request could not be written to the socket.
        public static let write: Code = "write"
    }
}
