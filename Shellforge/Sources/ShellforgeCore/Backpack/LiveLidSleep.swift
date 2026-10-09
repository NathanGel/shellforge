// Ported from AiTerm (app/Sources/AiTermCore/Backpack/LiveLidSleep.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// `pmset disablesleep` through `sudo -n`, which fails at once rather than asking for a password
/// when the rule is missing.
public struct SudoLidSleep: LidSleepControl {
    private let watchdog: any SleepWatchdogging
    private let run: @Sendable ([String]) -> Bool

    /// `watchdog` puts lid sleep back if Shellforge dies with it off; `run` is `sudo` with its
    /// arguments, for a test to stand in for.
    public init(watchdog: any SleepWatchdogging = SleepWatchdog(), run: (@Sendable ([String]) -> Bool)? = nil) {
        self.watchdog = watchdog
        self.run = run ?? { Self.sudo($0) }
    }

    public func isAllowed() -> Bool { run(["-n", "-l"] + pmset(1)) }

    /// Off arms the watchdog only once lid sleep is off; on lets it go only once lid sleep is back.
    public func setDisabled(_ disabled: Bool) -> Bool {
        let done = run(["-n"] + pmset(disabled ? 1 : 0))
        if done { disabled ? watchdog.arm() : watchdog.disarm() }
        return done
    }

    /// No `sudo`: any user may put the Mac to sleep.
    public func sleepNow() -> Bool {
        BackpackLog.attempt("Running pmset sleepnow") {
            try BackpackProcess.run(URL(fileURLWithPath: "/usr/bin/pmset"), ["sleepnow"], timeout: 10)
        }?.status == 0
    }

    private func pmset(_ value: Int) -> [String] { ["/usr/bin/pmset", "-a", "disablesleep", "\(value)"] }

    private static func sudo(_ arguments: [String]) -> Bool {
        // A refusal is an answer — the rule is missing — and is not logged; a sudo that cannot start is.
        BackpackLog.attempt("Running sudo \(arguments.joined(separator: " "))") {
            try BackpackProcess.run(URL(fileURLWithPath: "/usr/bin/sudo"), arguments, timeout: 10)
        }?.status == 0
    }
}

/// Installs and removes `SleepRule` through `osascript`'s admin prompt. No timeout: the person is
/// typing a password.
public struct AdminPromptInstaller: SleepRuleInstaller {
    private let user: String

    public init(user: String = NSUserName()) {
        self.user = user
    }

    public func install() -> Bool {
        guard let command = SleepRule.installCommand(user: user) else { return false }
        return runAsAdmin(command)
    }

    public func remove() -> Bool { runAsAdmin(SleepRule.removeCommand) }

    private func runAsAdmin(_ command: String) -> Bool {
        BackpackLog.attempt("Running the sleep rule's admin prompt") {
            try BackpackProcess.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", SleepRule.appleScript(running: command)])
        }?.status == 0
    }
}
