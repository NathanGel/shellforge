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

    /// One word of the command, as parts: the agent's own text, and where the first prompt goes.
    /// Each part is quoted on its own, so `--prompt={prompt}` comes out as `--prompt='fix it'`.
    enum Piece: Equatable {
        case text(String)
        case prompt
    }

    /// The words of the invocation, each in parts. The prompt goes where `{prompt}` stands in the
    /// agent's arguments, or is the last word when none does; with no prompt, or for an agent that
    /// doesn't take it as an argument, it isn't there. Shared by `build` and `previewCommand`, so
    /// the footer preview can never drift from the command that is actually run. The model and
    /// reasoning come from catalogues the app does not write, so every part is quoted as needed.
    static func pieces(agent: AgentDefinition, model: String, reasoning: String?, hasPrompt: Bool) -> [[Piece]] {
        let hasPrompt = hasPrompt && agent.prompt == .argument
        var out = agent.launchPieces(model: model, reasoning: reasoning, hasPrompt: hasPrompt)
        if hasPrompt, !out.contains(where: { $0.contains(.prompt) }) { out.append([.prompt]) }
        return out
    }

    /// A word of the command that can't be typed safely. A control character acts as a keystroke
    /// even inside quotes (^U erases the open quote, CR runs the rest of the line), and a backslash
    /// ends the quote for fish, which reads `\'` as an escape. A byte at 0x80 or above is a Meta
    /// keystroke to bash under a non-UTF-8 locale, so a word from a catalogue must be ASCII.
    public struct UnsafeWord: Error, Equatable, LocalizedError {
        public enum Reason: Equatable, Sendable { case control, backslash, nonASCII }
        public let field: String
        public let reason: Reason
        public var errorDescription: String? {
            switch reason {
            case .control: "The \(field) holds a control character, which can’t be typed into a terminal safely. Remove it in Settings › Agents."
            case .backslash: "The \(field) holds a backslash, which not every shell reads the same inside quotes. Remove it in Settings › Agents."
            case .nonASCII: "The \(field) holds a character outside ASCII, which some shells read as a keystroke. Choose another in Settings › Agents."
            }
        }
    }

    static func refuseUnsafe(_ text: String, field: String, backslash: Bool, asciiOnly: Bool = false) throws {
        if text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { throw UnsafeWord(field: field, reason: .control) }
        if backslash, text.contains("\\") { throw UnsafeWord(field: field, reason: .backslash) }
        if asciiOnly, !text.unicodeScalars.allSatisfy(\.isASCII) { throw UnsafeWord(field: field, reason: .nonASCII) }
    }

    /// The prompt as typed: a pasted Windows line ending is a newline, and nothing at all is nil.
    static func normalizedPrompt(_ prompt: String?) -> String? {
        prompt.map { $0.replacingOccurrences(of: "\r\n", with: "\n") }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The command's words, checked, and where the prompt goes. `prefix` is what the line starts
    /// with when it goes behind `shellforge-run`, whose every word is then quoted and which has no
    /// backslash: the limit on a typed line is on the whole of it.
    struct Plan {
        var pieces: [[Piece]]
        /// The prompt typed in the line, or nil.
        var inline: String?
        /// The prompt that goes through `.shellforge/first-prompt.md`, or nil.
        var file: String?
        var quoteAll: Bool
        var prefix: String

        var line: String { prefix + AgentCommand.line(pieces, inline: inline, quoteAll: quoteAll) }
    }

    static func plan(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?, prefix: String?) throws -> Plan {
        let backslash = prefix != nil
        try refuseUnsafe(agent.command, field: "command", backslash: backslash)
        for word in agent.arguments.joined() { try refuseUnsafe(word, field: "arguments", backslash: backslash) }
        // From catalogues the app does not write: typed, so ASCII only.
        try refuseUnsafe(model, field: "model", backslash: backslash, asciiOnly: true)
        if let reasoning { try refuseUnsafe(reasoning, field: "reasoning level", backslash: backslash, asciiOnly: true) }
        let prompt = normalizedPrompt(prompt)
        if prompt != nil, agent.prompt == .stdin { throw Unsupported(agent: agent.name) }
        let words = pieces(agent: agent, model: model, reasoning: reasoning, hasPrompt: prompt != nil)
        var plan = Plan(pieces: words, inline: nil, file: nil, quoteAll: prefix != nil, prefix: prefix ?? "")
        guard let prompt, agent.prompt == .argument else { return plan }
        plan.inline = prompt
        if readsFromFile(prompt, plan: plan) {
            plan.inline = nil
            plan.file = prompt
        }
        return plan
    }

    private static let promptFileExpansion = "\"$(cat .shellforge/first-prompt.md)\""

    /// `words` as the line a shell reads them from. `inline` is the prompt typed in the line, or nil
    /// for the file's expansion. Plain text is left bare when the shell would read it back unchanged;
    /// `quoteAll` quotes every part, for a line whose words must stay words (`shellforge-run`).
    static func line(_ words: [[Piece]], inline: String?, quoteAll: Bool = false) -> String {
        words.map { word in
            word.map { piece -> String in
                switch piece {
                case .text(let text): return quoteAll ? shellQuote(text) : shellWord(text)
                case .prompt: return inline.map(shellQuote) ?? promptFileExpansion
                }
            }.joined()
        }.joined(separator: " ")
    }

    /// An agent whose first prompt can't be passed: one that reads it from its standard input.
    public struct Unsupported: Error, Equatable, LocalizedError {
        public let agent: String
        public var errorDescription: String? { "\(agent) takes its first prompt in a way Shellforge can’t pass yet." }
    }

    /// The exact command a task would launch, built without touching the disk: a prompt that goes
    /// through the file shows the `$(cat …)` form the real build would produce, instead of
    /// pretending the prompt is inline. For the New Task footer (spec 4.4), where no worktree exists yet.
    public static func previewCommand(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?) -> String {
        let prompt = normalizedPrompt(prompt)
        let words = pieces(agent: agent, model: model, reasoning: reasoning, hasPrompt: prompt != nil)
        guard let prompt, agent.prompt == .argument else { return line(words, inline: nil) }
        let inline = Plan(pieces: words, inline: prompt, file: nil, quoteAll: false, prefix: "")
        return line(words, inline: readsFromFile(prompt, plan: inline) ? nil : prompt)
    }

    /// The first prompt's file was not written: `.shellforge`, or the file in it, is a symlink —
    /// one a checked-out branch (a merge request under review) can commit, to send the write
    /// anywhere the user can write. As `prepareWorktree` treats `.worktrees`.
    public struct SymlinkRefused: Error, Equatable, LocalizedError {
        public let path: String
        public var errorDescription: String? { "Refusing to write the first prompt through the symlink at \(path)." }
    }

    public static func build(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?, worktreePath: String,
                             launcher: CommandLauncher) throws -> String {
        try prepare(agent: agent, model: model, reasoning: reasoning, prompt: prompt, prefix: nil,
                    worktreePath: worktreePath, launcher: launcher).line
    }

    /// The plan, with the prompt's file written when it goes through one. `.typed` and `.noPrompt`
    /// leave the prompt out; `.stdin` can't take one.
    static func prepare(agent: AgentDefinition, model: String, reasoning: String?, prompt: String?, prefix: String?,
                        worktreePath: String, launcher: CommandLauncher) throws -> Plan {
        let plan = try plan(agent: agent, model: model, reasoning: reasoning, prompt: prompt, prefix: prefix)
        guard let file = plan.file else { return plan }
        let dir = worktreePath + "/.shellforge", path = dir + "/first-prompt.md"
        try refuseSymlink(at: dir)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // A committed link at the file itself is refused too, rather than written over.
        try refuseSymlink(at: path)
        try file.write(toFile: path, atomically: true, encoding: .utf8)
        excludeShellforgeDirectory(worktreePath: worktreePath, launcher: launcher)
        return plan
    }

    private static func refuseSymlink(at path: String) throws {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { throw SymlinkRefused(path: path) }
    }

    /// Whether the command reads `prompt` from `.shellforge/first-prompt.md` instead of carrying it.
    /// An inline prompt is typed into the terminal, where quoting does not stop a control character
    /// acting as a keystroke: TAB completes, CR accepts the line, ESC, ^C, ^D, ^U, ^W, ^R and DEL
    /// edit it. Only a newline is safe — inside the quotes, zsh just continues the line. The length
    /// is the whole typed command's, `invocation` and quoting included, against `inlineLimit`.
    ///
    /// A backslash goes through the file too: the tab runs the account's login shell, and fish reads
    /// `\'` and `\\` as escapes even inside single quotes, where zsh and bash read them as they are.
    /// So does any character outside ASCII: bash under a non-UTF-8 locale reads each byte at 0x80
    /// or above as a Meta keystroke, and U+0148 erases the word before it. A prompt can hold a
    /// ticket's or a merge request's text, which others write.
    private static func readsFromFile(_ prompt: String, plan: Plan) -> Bool {
        plan.line.utf8.count > inlineLimit
            || prompt.unicodeScalars.contains { $0 != "\n" && ($0.value < 0x20 || $0.value == 0x7F || !$0.isASCII) }
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

    /// The person's text, then — when they kept "Include Jira ticket details" — the ticket: its key,
    /// summary and description. Nothing when there is neither.
    public static func composePrompt(userText: String?, ticket: JiraTicket?, appendTicket: Bool) -> String? {
        var blocks: [String] = []
        if let t = userText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { blocks.append(t) }
        if appendTicket, let ticket {
            var block = "\(ticket.key): \(ticket.summary)"
            if let d = ticket.description?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { block += "\n\n" + d }
            blocks.append(block)
        }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
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

    /// `command` after an `export` of `environment`, sorted by name and each value quoted: how a
    /// task's tab gets its tunnels' ports, since an iTerm2 profile has no environment of its own.
    /// Nil when there is nothing to type.
    public static func exporting(_ environment: [String: String], then command: String?) -> String? {
        guard !environment.isEmpty else { return command }
        let exports = "export " + environment.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(AgentCommand.shellQuote($0.value))" }.joined(separator: " ")
        return command.map { "\(exports); \($0)" } ?? exports
    }
}
