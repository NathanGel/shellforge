// Ported from AiTerm (app/Sources/AiTermCore/Backpack/SleepRule.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The sudoers rule that lets Shellforge turn lid sleep off and on without a password — those two
/// `pmset` commands and nothing else — and the shell that installs and removes it under one admin
/// prompt.
public enum SleepRule {
    public static let path = "/etc/sudoers.d/shellforge"
    public static let commands = ["/usr/bin/pmset -a disablesleep 0", "/usr/bin/pmset -a disablesleep 1"]

    /// Nil for a user name sudoers could read as more than one name: only ASCII letters, digits,
    /// `.`, `_` and `-`, not starting with `-`.
    public static func text(user: String) -> String? {
        guard isSafe(user) else { return nil }
        return "# Installed by Shellforge for backpack mode. Remove with Mac Settings > Remove.\n"
            + "\(user) ALL=(root) NOPASSWD: \(commands.joined(separator: ", "))\n"
    }

    /// Writes the rule to a temporary file, has `visudo` check it, installs it only if it passed,
    /// and removes the temporary file whatever happened. Its lines hold no single quote.
    public static func installCommand(user: String) -> String? {
        guard let text = text(user: user) else { return nil }
        let lines = text.split(separator: "\n").map { "'\($0)'" }.joined(separator: " ")
        return "t=$(/usr/bin/mktemp) && /usr/bin/printf '%s\\n' \(lines) > \"$t\""
            + " && /usr/sbin/visudo -cf \"$t\""
            + " && /usr/bin/install -m 0440 -o root -g wheel \"$t\" \(path)"
            + "; s=$?; /bin/rm -f \"$t\"; exit $s"
    }

    public static let removeCommand = "/bin/rm -f /etc/sudoers.d/shellforge"

    /// `command` as an AppleScript that runs it as root after the system's password prompt.
    public static func appleScript(running command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    static func isSafe(_ user: String) -> Bool {
        guard let first = user.first, first != "-" else { return false }
        return user.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }
}
