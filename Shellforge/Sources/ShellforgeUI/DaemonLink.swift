import Combine
import Foundation
import ShellforgeCore

/// The app's one link to its helper: the daemon process, the socket to it, what it has said about
/// the sessions, and the tabs last sent to it. Every window's sidebar observes it.
@MainActor
public final class DaemonLink: ObservableObject {
    @Published public private(set) var status: HelperStatus = .starting
    /// The last tunnel call the helper refused, as the sidebar's error banner says it.
    @Published public private(set) var tunnelError: String?
    /// Each tunnel call's outcome once, as it happens: a window opened later hears none of the old.
    private let outcomes = PassthroughSubject<TunnelOutcome, Never>()
    public var tunnelOutcomes: AnyPublisher<TunnelOutcome, Never> { outcomes.eraseToAnyPublisher() }
    @Published public private(set) var store = SessionStore()

    private let socketPath: String
    private let daemonDir: URL?
    private let findPython: @Sendable () -> URL?
    private let reports: @MainActor () -> [SessionReport]
    /// The login shell's environment, which tunnels start with: the helper has none of its own.
    private let environment: @Sendable () -> [String: String]
    private var supervisor: DaemonSupervisor?
    private var connection: DaemonConnection?
    private var client: DaemonClient?
    private var startup: Task<Void, Never>?
    private var running = false
    /// The list the attached daemon last took; nil when it must be sent whatever it holds.
    private var lastSent: [SessionReport]?
    private var sending = false
    /// The attached client when it turned out not to take lists (`sessions.update` unknown to it).
    private weak var refused: DaemonClient?

    public init(socketPath: String = ShellforgePaths.socketPath, daemonDir: URL?,
                findPython: @escaping @Sendable () -> URL?, reports: @escaping @MainActor () -> [SessionReport],
                environment: @escaping @Sendable () -> [String: String] = { [:] }) {
        self.socketPath = socketPath
        self.daemonDir = daemonDir
        self.findPython = findPython
        self.reports = reports
        self.environment = environment
    }

    /// Looks for Python off the main thread — a login shell and a check per candidate — then starts
    /// the helper with it; the connection follows once the helper listens.
    public func start() {
        guard !running else { return }
        running = true
        guard let daemonDir, FileManager.default.fileExists(atPath: daemonDir.appendingPathComponent("shellforged/__main__.py").path) else {
            status = .helperMissing
            return
        }
        let findPython = self.findPython, socketPath = self.socketPath
        startup = Task {
            let found = await BackgroundWork.run { findPython() }
            guard !Task.isCancelled, running else { return }
            guard let python = found else { status = .pythonMissing; return }
            supervisor = DaemonSupervisor(python: python, daemonDir: daemonDir, socketPath: socketPath) { [weak self] state in
                Task { @MainActor in self?.supervisorChanged(state) }
            }
            supervisor?.start()
        }
    }

    /// Closes the socket, then stops the helper this app started: an orphan holding the socket
    /// would be adopted by the next launch whatever version it is.
    public func shutdown() {
        running = false
        startup?.cancel()
        connection?.stop()
        connection = nil
        supervisor?.stop()
        supervisor = nil
    }

    /// Reads `reports()` and sends it when it differs from the last list the daemon took. One send
    /// is in flight at a time; a change made meanwhile goes when it returns.
    public func reportsMayHaveChanged() {
        guard let client, client !== refused, !sending else { return }
        let current = reports()
        guard current != lastSent else { return }
        sending = true
        Task {
            do {
                try await client.updateSessions(current)
                if self.client === client { lastSent = current }
                sending = false
                // A change made while this one was in flight.
                reportsMayHaveChanged()
            } catch {
                // Not retried at once: a list refused every time would be resent for good. The next
                // change, tick or connection sends it again.
                sending = false
                lastSent = nil
                if let error = error as? DaemonError, error.isMismatch, self.client === client {
                    refused = client
                    status = .helperMismatch
                }
            }
        }
    }

    public func markSeen(task: UUID) {
        guard let client else { return }
        Task { _ = try? await client.markSeen(task: task) }
    }

    public func markSeen(sessions: [String]) {
        guard let client, !sessions.isEmpty else { return }
        Task { _ = try? await client.markSeen(sessions: sessions) }
    }

    /// Starts `alias`'s tunnel with the login environment, read off the main thread — the first
    /// read asks a login shell. Its state comes back as `tunnel.changed`.
    public func startTunnel(alias: String, keepRunning: Bool) {
        guard let client else { return }
        let environment = self.environment
        tunnelCall("start", alias, client) {
            let variables = await BackgroundWork.run { environment() }
            _ = try await client.startTunnel(alias: alias, environment: variables, keepRunning: keepRunning)
        }
    }

    public func holdTunnel(alias: String, port: Int, bind: String?) {
        guard let client else { return }
        tunnelCall("watch", alias, client) { _ = try await client.holdTunnel(alias: alias, port: port, bind: bind) }
    }

    public func stopTunnel(alias: String) {
        guard let client else { return }
        tunnelCall("stop", alias, client) { _ = try await client.stopTunnel(alias: alias) }
    }

    /// What the banner says of a failed tunnel call: the helper's refusal in the words its code
    /// has, or plainly that the connection dropped — never "The operation couldn't be completed".
    nonisolated static func tunnelMessage(_ verb: String, _ alias: String, _ error: Error) -> String {
        let reason = error is DaemonError ? error.localizedDescription : "the connection to Shellforge’s helper dropped."
        return "Couldn’t \(verb) tunnel \(alias): \(reason)"
    }

    /// A tunnel call, its refusal said rather than dropped; a helper this app cannot speak to is a
    /// mismatch, as a refused session list is. Not retried: the next click is the retry.
    private func tunnelCall(_ verb: String, _ alias: String, _ client: DaemonClient, _ call: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await call()
                // A reply from a helper since replaced is about a connection that is gone.
                guard self.client === client else { return }
                tunnelError = nil
                outcomes.send(TunnelOutcome(alias: alias, error: nil))
            } catch {
                guard self.client === client else { return }
                let message = Self.tunnelMessage(verb, alias, error)
                tunnelError = message
                outcomes.send(TunnelOutcome(alias: alias, error: message))
                if let error = error as? DaemonError, error.isMismatch {
                    refused = client
                    status = .helperMismatch
                }
            }
        }
    }

    func supervisorChanged(_ state: DaemonSupervisor.State) {
        switch state {
        case .listening, .adopted:
            if connection == nil {
                connection = DaemonConnection(socketPath: socketPath,
                    onClient: { [weak self] in self?.attached($0) },
                    onStatus: { [weak self] in self?.connectionSaid($0) },
                    onEvent: { [weak self] in self?.store.apply($0) })
            }
            connection?.start()
        // One failure is a restart in progress; from the second on the helper is stuck.
        case .failed(let attempt, let message): if attempt >= 2 { status = .helperFailing(message) }
        case .starting, .running, .stopped: break
        }
    }

    /// What the connection says about the helper, except where the link knows better: a helper that
    /// keeps stopping stays said between its restarts, and one that refused the list stays a mismatch.
    func connectionSaid(_ said: HelperStatus) {
        if case .helperFailing = status, said == .helperUnreachable { return }
        if said == .connected, let refused, refused === client { return }
        status = said
    }

    /// A new connection knows nothing this one sent; a lost one leaves no status worth showing.
    private func attached(_ client: DaemonClient?) {
        self.client = client
        lastSent = nil
        if client == nil { store = SessionStore() } else { reportsMayHaveChanged() }
    }
}

extension DaemonLink: SessionFeed {
    public var statusPublisher: AnyPublisher<HelperStatus, Never> { $status.eraseToAnyPublisher() }
    public var storePublisher: AnyPublisher<SessionStore, Never> { $store.eraseToAnyPublisher() }
    public var tunnelOutcomePublisher: AnyPublisher<TunnelOutcome, Never> { tunnelOutcomes }
}
