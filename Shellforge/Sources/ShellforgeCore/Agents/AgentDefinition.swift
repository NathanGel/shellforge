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
    /// Variables filled from the Keychain at launch: variable name → Keychain item name. The value
    /// itself is never written to the agent's file.
    public var secrets: [String: String]
    /// Where its status, context and usage come from.
    public var status: StatusSource

    public init(id: String, name: String, command: String, arguments: [[String]] = [], prompt: PromptDelivery = .argument,
                models: ModelSource = .fixed([]), reasoningLevels: [String] = [], defaultReasoning: String? = nil,
                environment: [String: String] = [:], secrets: [String: String] = [:], status: StatusSource = .terminal) {
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
    }

    /// How the first prompt reaches the agent.
    public enum PromptDelivery: String, Codable, Sendable {
        /// The last word of its command line.
        case argument
        /// Written to its standard input.
        case stdin
        /// Typed into it once it is running, as a person would.
        case typed
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
        /// The agent posts Shellforge's events (`shellforge-report`) from its hooks.
        case eventProtocol
        /// The agent exports token usage over OpenTelemetry.
        case openTelemetry
        /// Nothing reported: status from the terminal alone, and the dials say "not reported".
        case terminal
    }

    /// The command and its arguments for `model` and `reasoning`, unquoted.
    public func launchWords(model: String?, reasoning: String?, cwd: String? = nil) -> [String] {
        let values = ["{model}": model, "{reasoning}": reasoning, "{cwd}": cwd]
        let filled = arguments.compactMap { group -> [String]? in
            var words: [String] = []
            for word in group {
                var word = word
                for (placeholder, value) in values where word.contains(placeholder) {
                    guard let value, !value.isEmpty else { return nil }
                    word = word.replacingOccurrences(of: placeholder, with: value)
                }
                words.append(word)
            }
            return words
        }
        return [command] + filled.flatMap { $0 }
    }

    /// The line typed into the task's shell, the prompt last when it travels as an argument.
    public func commandLine(model: String?, reasoning: String?, prompt text: String?, cwd: String? = nil) -> String {
        var words = launchWords(model: model, reasoning: reasoning, cwd: cwd).map(ShellWords.word)
        if prompt == .argument, let text, !text.isEmpty { words.append(ShellWords.quote(text)) }
        return words.joined(separator: " ")
    }
}

/// Quoting for a POSIX shell's command line.
enum ShellWords {
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    /// `s` bare when the shell would read it back unchanged, else quoted.
    static func word(_ s: String) -> String {
        s.range(of: "^[A-Za-z0-9_@%+:,./-][A-Za-z0-9_@%+=:,./-]*$", options: .regularExpression) != nil ? s : quote(s)
    }
}
