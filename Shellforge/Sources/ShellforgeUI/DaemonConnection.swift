// Ported from AiTerm (app/Sources/AiTerm/DaemonConnection.swift), GPLv3, Laurens D'Hondt.
import Foundation
import ShellforgeCore

/// Owns exactly one socket/retry/event lifetime. Helper process supervision stays
/// separate: a running process is not evidence of a healthy app connection.
@MainActor
final class DaemonConnection {
    private let socketPath: String
    private let onClient: @MainActor (DaemonClient?) -> Void
    private let onStatus: @MainActor (HelperStatus) -> Void
    private let onEvent: @MainActor (DaemonEvent) -> Void
    /// The pause before retry number `attempt`; a test passes a short one.
    private let backoff: @Sendable (_ attempt: Int) -> TimeInterval
    /// How long a connection must hold after its snapshot for its end to start the backoff over,
    /// and, after one that ended as a mismatch, for what it says to be shown.
    private let steadyAfter: Duration
    private var lifetime: Task<Void, Never>?
    private var client: DaemonClient?

    init(socketPath: String, onClient: @escaping @MainActor (DaemonClient?) -> Void,
         onStatus: @escaping @MainActor (HelperStatus) -> Void, onEvent: @escaping @MainActor (DaemonEvent) -> Void,
         backoff: @escaping @Sendable (_ attempt: Int) -> TimeInterval = { Backoff.delay(attempt: $0) },
         steadyAfter: Duration = .seconds(5)) {
        self.socketPath = socketPath
        self.onClient = onClient
        self.onStatus = onStatus
        self.onEvent = onEvent
        self.backoff = backoff
        self.steadyAfter = steadyAfter
    }

    /// The retry loop holds this connection for as long as it runs, so releasing the connection
    /// does not end it: `stop()` does.
    func start() {
        guard lifetime == nil else { return }
        lifetime = Task { await self.run() }
    }

    /// Ends the retry loop and the client it has. Every owner calls it; nothing else will.
    func stop() {
        lifetime?.cancel()
        lifetime = nil
        client?.disconnect()
        client = nil
        onClient(nil)
    }

    private func run() async {
        var attempt = 0
        // Whether the last connection ended as a mismatch: a helper that does so ends the next
        // connection the same way, moments after its snapshot said "Connected", so what that one
        // says waits until it has held.
        var mismatched = false
        while !Task.isCancelled {
            let connection = DaemonClient(socketPath: socketPath)
            client = connection
            var attached: ContinuousClock.Instant?
            let statuses = HeldStatus(holding: mismatched, onStatus: onStatus)
            var steady: Task<Void, Never>?
            defer { steady?.cancel() }
            /// How this connection ended, said at once: whatever it held back no longer applies.
            func ended(_ status: HelperStatus) {
                steady?.cancel()
                mismatched = status == .helperMismatch
                onStatus(status)
            }
            do {
                try await BackgroundWork.run { try connection.connect() }
                let snapshot = try await connection.snapshot()
                try Task.checkCancellation()
                onClient(connection)
                statuses.report(.connected)
                attached = .now
                if statuses.holding {
                    steady = Task { [steadyAfter] in
                        guard (try? await Task.sleep(for: steadyAfter)) != nil else { return }
                        statuses.release()
                    }
                }
                var bootstrapped = false
                for await event in connection.events {
                    guard !Task.isCancelled else { break }
                    if case .snapshot = event {
                        bootstrapped = true
                        statuses.report(.connected)
                    }
                    // Earlier buffered events must not overwrite the bootstrap snapshot.
                    guard bootstrapped else { continue }
                    onEvent(event)
                }
                // A helper that sent what this app cannot read sends it again on the next connection:
                // one this app cannot speak to, as with a snapshot it cannot read, not one gone away.
                if !Task.isCancelled { ended(connection.ending == .unreadable ? .helperMismatch : .helperUnreachable) }
            } catch {
                if !Task.isCancelled {
                    // A helper we cannot fully understand — a stale protocol version, or a snapshot
                    // with a shape this app's `Decodable`s reject — is not the same as one that is
                    // merely unreachable; retrying at it forever would never fix either.
                    if let error = error as? DaemonError, error.isMismatch {
                        ended(.helperMismatch)
                    } else if error is DecodingError {
                        ended(.helperMismatch)
                    } else { ended(.helperUnreachable) }
                }
            }
            connection.disconnect()
            if client === connection { client = nil; onClient(nil) }
            guard !Task.isCancelled else { break }
            // A connection that held is a helper that works, and its end starts the backoff over.
            // One that ended moments after its snapshot will end so again: each retry waits longer,
            // rather than reconnecting to it once a second.
            if let attached, ContinuousClock.now - attached >= steadyAfter { attempt = 0 }
            do { try await Task.sleep(for: .seconds(backoff(attempt))) }
            catch { break }
            attempt += 1
        }
    }
}

/// What one connection says, held back while `holding`: the last of it is said when the
/// connection has held long enough to be believed (`release`), and none of it if it ends first.
@MainActor
private final class HeldStatus {
    private let onStatus: @MainActor (HelperStatus) -> Void
    private(set) var holding: Bool
    private var held: HelperStatus?

    init(holding: Bool, onStatus: @escaping @MainActor (HelperStatus) -> Void) {
        self.holding = holding
        self.onStatus = onStatus
    }

    func report(_ status: HelperStatus) {
        if holding { held = status } else { onStatus(status) }
    }

    func release() {
        guard holding else { return }
        holding = false
        if let held { onStatus(held) }
    }
}
