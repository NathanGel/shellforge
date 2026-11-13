import Foundation

/// What a tab runs on files: the editor on a file, `git diff` on a change. The tab's own command is
/// the login shell running a fixed script, with the files' paths as the shell's own arguments:
/// nothing derived from a file's name is typed into the terminal or read by a shell as code. A path
/// comes from the repository, so a cloned one decides it; typed, a byte of it could act as a
/// keystroke (bash reads one at 0x80 or above as Meta under a non-UTF-8 locale), and quoting stops
/// none of that.
///
/// The script's own text — the editor setting, git's options — is trusted. A relative path goes
/// behind `./`, so no argument starts with `+` or `-` and an editor never reads it as an option
/// (vim runs `+!cmd` and `-c!cmd`).
public struct FileCommand: Equatable, Sendable {
    /// One piece of the script: trusted text, or the shell's argument holding `paths[index]`.
    public enum Part: Equatable, Sendable {
        case text(String)
        case path(Int)
    }

    public let parts: [Part]
    /// The script's arguments, each already in the form the program takes (`./a.md`, `:(literal)./a.md`).
    public let paths: [String]
    /// The shell goes on after the program, as a login shell, rather than the program replacing it:
    /// a diff's pager quits at once on a short one, which would close the tab before it was read.
    public let keepsShell: Bool

    /// A path holding a control character: nothing opens for it. One has no business in a terminal
    /// title or an argument list.
    public struct Unsafe: Error, Equatable, LocalizedError {
        public init() {}
        public var message: String { "This file’s name has a control character in it, so it can’t be opened in a terminal." }
        public var errorDescription: String? { message }
    }

    /// `$0` of a POSIX shell's script: what `ps` shows for it.
    public static let scriptName = "shellforge-open"

    /// Editors whose command line takes `--` before file names.
    private static let endOfOptionsEditors: Set<String> = ["vi", "vim", "nvim"]

    /// Shells that take `-l -i -c <script> <$0> <args…>` and read `"$1"`.
    private static let posixShells: Set<String> = ["sh", "bash", "zsh", "ksh", "mksh", "dash", "yash"]

    /// Shells of the csh family: they reject `-l` with `-c`, and log in when their argv[0] starts
    /// with `-`, which iTerm2's ShellLauncher (`--launch_shell`) gives them.
    private static let cshShells: Set<String> = ["csh", "tcsh"]

    /// Used to run the script when the login shell takes none of these forms (nu, elvish, xonsh),
    /// or a csh-family shell when no ShellLauncher is at hand.
    static let fallbackShell = "/bin/zsh"

    public init(parts: [Part], paths: [String], keepsShell: Bool) {
        self.parts = parts
        self.paths = paths
        self.keepsShell = keepsShell
    }

    /// Throws `Unsafe` for a path holding a scalar below 0x20 or DEL.
    public static func refuseUnsafe(_ path: String) throws {
        if path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { throw Unsafe() }
    }

    /// `path` as the program's argument: checked, behind `./` when relative, and as a literal
    /// pathspec (`:(literal)…`) when `pathspec`.
    public static func argument(_ path: String, pathspec: Bool = false) throws -> String {
        try refuseUnsafe(path)
        let anchored = path.hasPrefix("/") ? path : "./" + path
        return pathspec ? ":(literal)" + anchored : anchored
    }

    /// Whether `editor`, the command as typed (`nvim -p`), takes `--` before its file names: its
    /// first word's last path component is one known to.
    public static func acceptsEndOfOptions(_ editor: String) -> Bool {
        guard let program = editor.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return false }
        return endOfOptionsEditors.contains((String(program) as NSString).lastPathComponent)
    }

    enum Family { case posix, fish, csh }

    /// The tab's command: `shell`, the account's login shell, as a login, interactive shell (its
    /// `PATH` and aliases, as a typed line had) running the script, the paths its arguments. fish
    /// sets `$argv` from what follows the script; a POSIX shell takes `$0` first. tcsh and csh are
    /// started through `shellLauncher` (iTerm2's ShellLauncher), which logs them in by argv[0] as
    /// it does for a profile's login shell; they set `$argv` from what follows the script. Any
    /// other shell runs the script under `fallbackShell`, and is the shell a diff's tab goes on in.
    public func argv(shell: String, shellLauncher: String? = nil) -> [String] {
        let name = (shell as NSString).lastPathComponent
        if name == "fish" {
            return [shell, "-l", "-i", "-c", script(.fish, then: shell)] + paths
        }
        if Self.cshShells.contains(name), let shellLauncher {
            return [shellLauncher, "--launch_shell", "SHELL=" + shell, "-i", "-c", script(.csh, then: shell)] + paths
        }
        let runner = Self.posixShells.contains(name) ? shell : Self.fallbackShell
        return [runner, "-l", "-i", "-c", script(.posix, then: shell), Self.scriptName] + paths
    }

    func script(_ family: Family, then shell: String) -> String {
        let body = parts.map { part -> String in
            switch part {
            case .text(let text): return text
            case .path(let index):
                switch family {
                case .fish: return "\"$argv[\(index + 1)]\""
                // `:q` keeps the value one word with nothing in it substituted again.
                case .csh: return "$argv[\(index + 1)]:q"
                case .posix: return "\"$\(index + 1)\""
                }
            }
        }.joined()
        guard keepsShell else { return "exec " + body }
        // `-l` only where the shell takes it after `exec`: a POSIX shell or fish. Any other goes on
        // as a plain interactive shell.
        let name = (shell as NSString).lastPathComponent
        let login = name == "fish" || Self.posixShells.contains(name)
        return body + "; exec " + Self.word(shell, family) + (login ? " -l" : "")
    }

    /// A trusted word (the shell's own path) for `family`: bare when nothing in it is special.
    private static func word(_ s: String, _ family: Family) -> String {
        if s.range(of: "^[A-Za-z0-9_@%+:,./-]+$", options: .regularExpression) != nil { return s }
        switch family {
        case .posix, .csh: return AgentCommand.shellQuote(s)
        case .fish: return "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
        }
    }

    /// The program run, as a person would type it (for logs and tests): never typed by Shellforge.
    public var line: String {
        parts.map { part -> String in
            switch part {
            case .text(let text): return text
            case .path(let index): return AgentCommand.shellWord(paths[index])
            }
        }.joined()
    }
}
