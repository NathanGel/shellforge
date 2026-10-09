// Ported from AiTerm (app/Sources/AiTermCore/Backpack/LiveLidSleep.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// `pmset disablesleep` through `sudo -n`, which fails at once rather than asking for a password
/// when the rule is missing.
public struct SudoLidSleep: LidSleepControl {
    public init() {}

    public func isAllowed() -> Bool { sudo(["-n", "-l"] + pmset(1)) }

    public func setDisabled(_ disabled: Bool) -> Bool { sudo(["-n"] + pmset(disabled ? 1 : 0)) }

    /// No `sudo`: any user may put the Mac to sleep.
    public func sleepNow() -> Bool {
        BackpackLog.attempt("Running pmset sleepnow") {
            try BackpackProcess.run(URL(fileURLWithPath: "/usr/bin/pmset"), ["sleepnow"], timeout: 10)
        }?.status == 0
    }

    private func pmset(_ value: Int) -> [String] { ["/usr/bin/pmset", "-a", "disablesleep", "\(value)"] }

    private func sudo(_ arguments: [String]) -> Bool {
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
