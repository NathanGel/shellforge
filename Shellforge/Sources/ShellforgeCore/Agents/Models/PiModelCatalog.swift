// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/PiModelCatalog.swift), GPLv3, Laurens D'Hondt.
import Foundation

public enum PiModelCatalogError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case failed(Int32, String)
    case malformed(String)

    /// The failure in a sentence, as Settings' Models check says it.
    public var summary: String {
        if case .unavailable = self { return "PI couldn’t be launched." }
        return "The PI model catalogue is unavailable."
    }

    /// What the New Task sheet says in place of PI's models when it has none to offer: the
    /// summary, with PI's own last line of complaint when it gave one.
    public var errorDescription: String? {
        guard case .failed(_, let stderr) = self,
              let reason = stderr.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty })
        else { return summary }
        return String(summary.dropLast()) + ": " + reason
    }
}

public enum PiModelCatalog {
    public static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// PI's table, one row a model. With no provider signed in PI prints a sentence instead — "No
    /// models available. Use /login …" — and exits 0: that is an empty list, not a broken one.
    public static func parse(_ output: String) throws -> [AgentModel] {
        let lines = output.split(whereSeparator: \Character.isNewline)
        guard let first = lines.first, !first.hasPrefix("No models available") else { return [] }
        let header = lines[0].split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard header == ["provider", "model", "context", "max-out", "thinking", "images"] else {
            throw PiModelCatalogError.malformed("Unexpected PI model-list header")
        }
        return try lines.dropFirst().map { line in
            let fields = line.split(whereSeparator: \Character.isWhitespace).map(String.init)
            guard fields.count == 6,
                  ["yes", "no"].contains(fields[4]),
                  ["yes", "no"].contains(fields[5]) else {
                throw PiModelCatalogError.malformed("Malformed PI model row: \(line)")
            }
            let supportsThinking = fields[4] == "yes"
            let imageText = fields[5] == "yes" ? "images" : "no images"
            return AgentModel(id: "\(fields[0])/\(fields[1])",
                              label: "\(fields[0]) / \(fields[1])",
                              detail: "\(fields[2]) context · \(fields[3]) max · \(imageText)",
                              efforts: supportsThinking ? thinkingLevels : [],
                              defaultEffort: supportsThinking ? AgentPresets.pi.defaultReasoning : nil)
        }
    }

    /// PI's models, from `pi --offline --list-models`, launched through the login shell's
    /// environment and killed after five seconds. `ModelCatalogue` is what the app asks.
    static func discover(executable: String, launcher: CommandLauncher) throws -> [AgentModel] {
        let result: ChildOutput
        do { result = try launcher.run(executable, ["--offline", "--list-models"], extra: ["PI_OFFLINE": "1"], timeout: 5) }
        catch { throw PiModelCatalogError.unavailable }
        guard !result.timedOut, result.status == 0 else {
            throw PiModelCatalogError.failed(result.status, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try parse(result.stdout)
    }
}
