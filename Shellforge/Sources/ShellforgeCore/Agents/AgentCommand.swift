// Ported from AiTerm (app/Sources/AiTermCore/Agents/AgentCommand.swift), GPLv3, Laurens D'Hondt.
import Foundation

public enum AgentCommand {
    /// The longest command typed inline, in bytes. It is typed into a tab whose shell may not have
    /// started its line editor yet, and until it does the terminal is in canonical mode, where macOS
    /// holds at most 1024 bytes of input (`MAX_CANON`) and drops the rest without a word: the closing
    /// quote goes, and zsh waits at `quote>`. The margin covers the daemon's leading space and newline.
    static let inlineLimit = 1000

    public static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// `s` as one word of a zsh command line: as it is when it holds nothing zsh would expand or
    /// split, quoted otherwise. A model id such as `claude-fable-5-1[1m]` is a glob to zsh, and one
    /// that matches no file fails the whole line with "no matches found". `=` is safe anywhere but
    /// first, where zsh's EQUALS option expands `=name` to that command's path.
    static func shellWord(_ s: String) -> String {
        s.range(of: "^[A-Za-z0-9_@%+:,./-][A-Za-z0-9_@%+=:,./-]*$", options: .regularExpression) != nil ? s : shellQuote(s)
    }

    /// The invocation without its prompt argument — shared by `build` and `previewCommand` so the
    /// footer preview can never drift from the command that is actually run. Every word goes
    /// through `shellWord`: the model and reasoning come from catalogues the app does not write.
    static func invocation(agent: AgentDefinition, model: String, reasoning: String?) -> [String] {
        agent.launchWords(model: model, reasoning: reasoning).map(shellWord)
    }

    /// An agent whose first prompt does not travel as the command's last word: written to its
    /// input or typed into it once it runs. Every preset takes it as a word; the other two arrive
    /// with custom agents (M3).
    public struct Unsupported: Error, Equatable, LocalizedError {
        public let agent: String
        public var errorDescription: String? { "\(agent) takes its first prompt in a way Shellforge can’t pass yet." }
    }

    /// The exact command a task would launch, built without touching the disk: a prompt that goes
    /// through the file shows the `$(cat …)` form the real build would produce, instead of
    /// pretending the prompt is inline. For the New Task footer (spec 4.4), where no worktree exists yet.
    public static func previewCommand(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?) -> String {
        var parts = invocation(agent: agent, model: model, reasoning: reasoning)
        if let prompt = prompt.map(normalized), !prompt.isEmpty {
            parts.append(readsFromFile(prompt, after: parts) ? "\"$(cat .shellforge/first-prompt.md)\"" : shellQuote(prompt))
        }
        return parts.joined(separator: " ")
    }

    public static func build(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?, worktreePath: String,
                             launcher: CommandLauncher) throws -> String {
        var parts = invocation(agent: agent, model: model, reasoning: reasoning)
        if let prompt = prompt.map(normalized), !prompt.isEmpty {
            guard agent.prompt == .argument else { throw Unsupported(agent: agent.name) }
            if readsFromFile(prompt, after: parts) {
                let dir = worktreePath + "/.shellforge"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try prompt.write(toFile: dir + "/first-prompt.md", atomically: true, encoding: .utf8)
                excludeShellforgeDirectory(worktreePath: worktreePath, launcher: launcher)
                parts.append("\"$(cat .shellforge/first-prompt.md)\"")
            } else {
                parts.append(shellQuote(prompt))
            }
        }
        return parts.joined(separator: " ")
    }

    /// A pasted Windows line ending is a newline, not the CR that would accept the line early.
    private static func normalized(_ prompt: String) -> String { prompt.replacingOccurrences(of: "\r\n", with: "\n") }

    /// Whether the command reads `prompt` from `.shellforge/first-prompt.md` instead of carrying it.
    /// An inline prompt is typed into the terminal, where quoting does not stop a control character
    /// acting as a keystroke: TAB completes, CR accepts the line, ESC, ^C, ^D, ^U, ^W, ^R and DEL
    /// edit it. Only a newline is safe — inside the quotes, zsh just continues the line. The length
    /// is the whole typed command's, `invocation` and quoting included, against `inlineLimit`.
    ///
    /// A backslash goes through the file too: the tab runs the account's login shell, and fish reads
    /// `\'` and `\\` as escapes even inside single quotes, where zsh and bash read them as they are.
    private static func readsFromFile(_ prompt: String, after invocation: [String]) -> Bool {
        (invocation + [shellQuote(prompt)]).joined(separator: " ").utf8.count > inlineLimit
            || prompt.unicodeScalars.contains { $0 != "\n" && ($0.value < 0x20 || $0.value == 0x7F) }
            || prompt.contains("\\")
    }

    /// Best-effort addition of `.shellforge/` to the repository's exclude file, which for a linked
    /// worktree lives in the common git directory. It never fails the command: a folder that is no
    /// repository simply has none.
    private static func excludeShellforgeDirectory(worktreePath: String, launcher: CommandLauncher) {
        guard let out = try? launcher.run("git", ["-C", worktreePath, "rev-parse", "--git-common-dir"]), out.status == 0 else { return }
        let gitDir = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try? TaskWorktrees.exclude(".shellforge/", inGitDir: gitDir.hasPrefix("/") ? gitDir : worktreePath + "/" + gitDir)
    }

    /// The person's text, trimmed; nothing when there is none. (AiTerm appends the Jira ticket here;
    /// that returns with M1d.)
    public static func composePrompt(userText: String?) -> String? {
        guard let t = userText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}

/// The line a task's tab types into its shell when it starts. iTerm2 sends a profile's initial
/// text through its interpolated-string evaluator, where `\(…)` is evaluated, so every backslash is
/// doubled as iTerm2 itself does (`iTermApplicationDelegate.m`). The leading space keeps the
/// command out of a history that ignores spaced lines, as AiTerm typed it.
public enum TabCommand {
    public static func initialText(_ command: String) -> String {
        " " + command.replacingOccurrences(of: "\\", with: "\\\\")
    }
}
