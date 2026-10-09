import Foundation

/// What `SudoLidSleep` arms when it turns lid sleep off and lets go when it turns it back on.
public protocol SleepWatchdogging: Sendable {
    func arm()
    func disarm()
}

/// A child that turns lid sleep back on the moment Shellforge lets go of it — on purpose after a
/// turn-off, or because Shellforge crashed or was force-quit. AiTerm's only defence was the marker
/// its next launch reads; until that launch a Mac could sit sleepless in a bag. This closes the gap:
/// the child waits on a pipe Shellforge holds, and when the pipe closes it runs `sudo -n pmset -a
/// disablesleep 0` through the same sudoers rule. A turn-off that already succeeded makes it run
/// once more, which changes nothing.
public final class SleepWatchdog: SleepWatchdogging, @unchecked Sendable {
    private let command: [String]
    private let lock = NSLock()
    private var held: FileHandle?

    public init(command: [String] = ["/bin/sh", "-c", "/bin/cat >/dev/null; /usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"]) {
        self.command = command
    }

    /// Starts the child, once; a second arm while one waits does nothing.
    public func arm() {
        lock.lock(); defer { lock.unlock() }
        guard held == nil, let executable = command.first else { return }
        held = BackpackLog.attempt("Arming the sleep watchdog") {
            try ChildProcess.holding(executable, Array(command.dropFirst()),
                                     environment: LoginEnvironment.forChildren(ProcessInfo.processInfo.environment))
        }
    }

    /// Lets the child go: it runs its command and ends.
    public func disarm() {
        lock.lock(); defer { lock.unlock() }
        try? held?.close()
        held = nil
    }
}
