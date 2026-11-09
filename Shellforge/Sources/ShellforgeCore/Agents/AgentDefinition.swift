import Foundation

/// One coding agent Shellforge can start in a task's tab: a preset (Claude Code, Codex, Grok Build,
/// PI) or one the user added by entering its command — a frontier CLI, or a local model behind one.
public struct AgentDefinition: Codable, Equatable, Sendable, Identifiable {
    /// The file name it is saved under, and how a task remembers its agent.
    public var id: String
    public var name: String
    /// The executable, by name — found on the login shell's `PATH` (`CommandLauncher`) — or by path.
    public var command: String
    /// The words after the command, in groups. `{model}`, `{reasoning}` and `{cwd}` are filled in;
    /// a group whose placeholder has no value is left out whole, so `["--effort", "{reasoning}"]`
    /// disappears when no reasoning level is picked.
    public var arguments: [[String]]
    public var prompt: PromptDelivery
    public var models: ModelSource
    /// The reasoning levels offered, and the one picked by default; empty when the agent has none.
    public var reasoningLevels: [String]
    public var defaultReasoning: String?
    /// Set in the agent's environment, over the login shell's. Plain values only: a key or token is
    /// a `secrets` entry instead.
    public var environment: [String: String]
    /// Variables filled from the Keychain at launch: variable name → the name of its entry in the
    /// app's Keychain item (`AgentSecrets.item`). Settings › Agents writes `agent.<id>.<VARIABLE>`; a
    /// hand-written file may name its own within `agent.`, and an empty or other name means the
    /// form's. The value itself is never written to the agent's file.
    public var secrets: [String: String]
    /// Where its status, context and usage come from.
    public var status: StatusSource
    /// For an agent whose status is `.eventProtocol`: the settings file to edit and the lines to add
    /// to it, with `{shellforge-status}` standing for the command that reports. Encoded only when set.
    public var statusSetup: StatusSetup?
    /// What the agent is, in a sentence or two, for Settings › Agents: a ready-made agent's
    /// `x-description`. Encoded only when set.
    public var about: String?
    /// What to mind when adding `statusSetup`'s lines to the agent's settings: a ready-made agent's
    /// `x-statusSetupNote`. Encoded only when set.
    public var statusSetupNote: String?

    /// The keys a file holds for the fields above. A save keeps every other key the file had.
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, command, arguments, prompt, models, reasoningLevels, defaultReasoning, environment, secrets, status, statusSetup
        case about = "x-description", statusSetupNote = "x-statusSetupNote"
    }

    /// An agent that takes no model: it isn't built in (a built-in's models come from its own files),
    /// and it lists none. New Task hides Model and Reasoning for it, and a task starts it with none.
    public var takesNoModel: Bool { !AgentPresets.isBuiltIn(id) && models == .fixed([]) }

    /// The text in `arguments` where the first prompt goes, for an agent that takes it as an argument.
    public static let promptPlaceholder = "{prompt}"

    public init(id: String, name: String, command: String, arguments: [[String]] = [], prompt: PromptDelivery = .argument,
                models: ModelSource = .fixed([]), reasoningLevels: [String] = [], defaultReasoning: String? = nil,
                environment: [String: String] = [:], secrets: [String: String] = [:], status: StatusSource = .terminal, statusSetup: StatusSetup? = nil,
                about: String? = nil, statusSetupNote: String? = nil) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.prompt = prompt
        self.models = models
        self.reasoningLevels = reasoningLevels
        self.defaultReasoning = defaultReasoning
        self.environment = environment
        self.secrets = secrets
        self.status = status
        self.statusSetup = statusSetup
        self.about = about
        self.statusSetupNote = statusSetupNote
    }

    /// How the first prompt reaches the agent.
    public enum PromptDelivery: String, Codable, Sendable {
        /// Where `{prompt}` stands in its arguments, or as the last word when none does.
        case argument
        /// Written to its standard input.
        case stdin
        /// Typed into it once it is running, as a person would.
        case typed
        /// It starts with no prompt.
        case noPrompt = "none"
    }

    /// The lines an agent with exact status needs in its own settings.
    public struct StatusSetup: Codable, Equatable, Sendable {
        /// The agent's settings file, as the person would name it.
        public var file: String
        /// The lines to add, holding `{shellforge-status}` where the reporting command goes.
        public var snippet: String

        public init(file: String, snippet: String) {
            self.file = file
            self.snippet = snippet
        }
    }

    /// Where the model picker's list comes from.
    public enum ModelSource: Codable, Equatable, Sendable {
        case fixed([String])
        /// A command that prints one model per line.
        case command([String])
    }

    /// Where status, context and usage come from, best first.
    public enum StatusSource: Codable, Equatable, Sendable {
        /// A built-in adapter: the agent's own hooks, status line and logs.
        case preset(String)
        /// Exact: the agent posts Shellforge's events (`shellforge-status`) from its hooks.
        case eventProtocol
        /// The agent exports token usage over OpenTelemetry.
        case openTelemetry
        /// Automatic: nothing reported. Status comes from the terminal alone, and the dials say "not reported".
        case terminal
    }

    /// The command and its arguments for `model` and `reasoning`, unquoted. A group holding
    /// `{prompt}` is left out: the prompt is `AgentCommand`'s to place.
    public func launchWords(model: String?, reasoning: String?, cwd: String? = nil) -> [String] {
        launchPieces(model: model, reasoning: reasoning, cwd: cwd, hasPrompt: false).map { word in
            word.reduce(into: "") { if case .text(let text) = $1 { $0 += text } }
        }
    }

    /// The command and its arguments as words in parts. Each word is split at `{prompt}` first and
    /// `{model}`, `{reasoning}` and `{cwd}` are filled in the parts after, so a value that holds
    /// `{prompt}` is only text. With `hasPrompt` the `{prompt}` parts are `.prompt`; without, a group
    /// holding one is left out whole, as is a group whose other placeholder has no value.
    func launchPieces(model: String?, reasoning: String?, cwd: String? = nil, hasPrompt: Bool) -> [[AgentCommand.Piece]] {
        let values = ["{model}": model, "{reasoning}": reasoning, "{cwd}": cwd]
        func word(_ source: String) -> [AgentCommand.Piece]? {
            var parts: [AgentCommand.Piece] = []
            for (i, text) in source.components(separatedBy: Self.promptPlaceholder).enumerated() {
                if i > 0 {
                    guard hasPrompt else { return nil }
                    parts.append(.prompt)
                }
                var text = text
                for (placeholder, value) in values where text.contains(placeholder) {
                    guard let value, !value.isEmpty else { return nil }
                    text = text.replacingOccurrences(of: placeholder, with: value)
                }
                if !text.isEmpty { parts.append(.text(text)) }
            }
            return parts.isEmpty ? [.text("")] : parts
        }
        let groups = arguments.compactMap { group -> [[AgentCommand.Piece]]? in
            var words: [[AgentCommand.Piece]] = []
            for source in group {
                guard let filled = word(source) else { return nil }
                words.append(filled)
            }
            return words
        }
        return [[.text(command)]] + groups.flatMap { $0 }
    }

    /// The line typed into the task's shell, the prompt last when it travels as an argument.
    public func commandLine(model: String?, reasoning: String?, prompt text: String?, cwd: String? = nil) -> String {
        var words = launchWords(model: model, reasoning: reasoning, cwd: cwd).map(ShellWords.word)
        if prompt == .argument, let text, !text.isEmpty { words.append(ShellWords.quote(text)) }
        return words.joined(separator: " ")
    }
}

/// Quoting for a POSIX shell's command line, and reading one back.
public enum ShellWords {
    public static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// `s` bare when the shell would read it back unchanged, else quoted.
    public static func word(_ s: String) -> String {
        s.range(of: "^[A-Za-z0-9_@%+:,./-][A-Za-z0-9_@%+=:,./-]*$", options: .regularExpression) != nil ? s : quote(s)
    }

    /// `s` as a POSIX shell reads it into words: blanks separate, single quotes keep everything,
    /// double quotes keep everything but `\"`, `\$`, a backtick and `\\` after a backslash, and a
    /// backslash outside quotes keeps the next character. Nil when a quote is never closed.
    public static func split(_ s: String) -> [String]? {
        var words: [String] = []
        var current = "", inWord = false
        var quote: Character?
        var chars = s.makeIterator()
        while let c = chars.next() {
            if quote == "'" {
                if c == "'" { quote = nil } else { current.append(c) }
            } else if quote == "\"" {
                if c == "\"" {
                    quote = nil
                } else if c == "\\" {
                    guard let next = chars.next() else { current.append(c); continue }
                    if !"\"$`\\\n".contains(next) { current.append(c) }
                    current.append(next)
                } else {
                    current.append(c)
                }
            } else if c == "'" || c == "\"" {
                quote = c
                inWord = true
            } else if c == "\\" {
                inWord = true
                current.append(chars.next() ?? c)
            } else if c == " " || c == "\t" || c == "\n" {
                if inWord { words.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(c)
                inWord = true
            }
        }
        guard quote == nil else { return nil }
        if inWord { words.append(current) }
        return words
    }
}
