import Combine
import Foundation
import ShellforgeCore

/// The app's one link to its helper: the daemon process, the socket to it, what it has said about
/// the sessions, and the tabs last sent to it. Every window's sidebar observes it.
@MainActor
public final class DaemonLink: ObservableObject {
    @Published public private(set) var status: HelperStatus = .starting
    @Published public private(set) var store = SessionStore()

    private let socketPath: String
    private let daemonDir: URL?
    private let findPython: @Sendable () -> URL?
    private let reports: @MainActor () -> [SessionReport]
    private var supervisor: DaemonSupervisor?
    private var connection: DaemonConnection?
    private var client: DaemonClient?
    private var startup: Task<Void, Never>?
    private var running = false
    /// The list the attached daemon last took; nil when it must be sent whatever it holds.
    private var lastSent: [SessionReport]?
    private var sending = false

    public init(socketPath: String = ShellforgePaths.socketPath, daemonDir: URL?,
                findPython: @escaping @Sendable () -> URL?, reports: @escaping @MainActor () -> [SessionReport]) {
        self.socketPath = socketPath
        self.daemonDir = daemonDir
        self.findPython = findPython
        self.reports = reports
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
        guard let client, !sending else { return }
        let current = reports()
        guard current != lastSent else { return }
        sending = true
        Task {
            do {
                try await client.updateSessions(current)
                if self.client === client { lastSent = current }
            } catch {
                lastSent = nil
            }
            sending = false
            reportsMayHaveChanged()
        }
    }

    public func markSeen(task: UUID) {
        guard let client else { return }
        Task { _ = try? await client.markSeen(task: task) }
    }

    func supervisorChanged(_ state: DaemonSupervisor.State) {
        switch state {
        case .listening, .adopted:
            if connection == nil {
                connection = DaemonConnection(socketPath: socketPath,
                    onClient: { [weak self] in self?.attached($0) },
                    onStatus: { [weak self] in self?.status = $0 },
                    onEvent: { [weak self] in self?.store.apply($0) })
            }
            connection?.start()
        // One failure is a restart in progress; from the second on the helper is stuck.
        case .failed(let attempt, let message): if attempt >= 2 { status = .helperFailing(message) }
        case .starting, .running, .stopped: break
        }
    }

    /// A new connection knows nothing this one sent; a lost one leaves no status worth showing.
    private func attached(_ client: DaemonClient?) {
        self.client = client
        lastSent = nil
        if client == nil { store = SessionStore() } else { reportsMayHaveChanged() }
    }
}
