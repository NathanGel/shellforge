import Foundation

/// The agents a task can start: the presets, then every agent saved in `folder`, one JSON file
/// each — `~/Library/Application Support/Shellforge/agents/` by default — so a set of agents can
/// be copied to another Mac. A saved agent with a preset's id replaces that preset.
public struct AgentRegistry: Sendable {
    public let folder: URL
    private let trash: @Sendable (URL) throws -> Void

    /// `trash` disposes of a removed agent's file; the default moves it to the user's Trash, so a
    /// removal can be undone from Finder.
    public init(folder: URL = AgentRegistry.defaultFolder,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.folder = folder
        self.trash = trash
    }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellforge/agents", isDirectory: true)
    }

    public struct Loaded: Equatable, Sendable {
        public var agents: [AgentDefinition]
        /// Files that could not be read; the other agents load regardless.
        public var problems: [Problem]
    }

    public struct Problem: Equatable, Sendable {
        public var file: String
        public var reason: String
    }

    public enum Refusal: Error, Equatable {
        /// A preset that was never overridden has no file to remove.
        case isPreset(String)
        case notFound(String)
        /// An id is a file name: letters, digits, `-` and `_` only.
        case invalidId(String)
        /// A key or token typed as a plain environment variable; it belongs in `secrets`, as a
        /// Keychain reference, so it is never written to disk.
        case secretInEnvironment(String)
    }

    public func load() throws -> Loaded {
        var agents = AgentPresets.all
        var problems: [Problem] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.deletingPathExtension().lastPathComponent < $1.deletingPathExtension().lastPathComponent }) {
            do {
                let agent = try JSONDecoder().decode(AgentDefinition.self, from: Data(contentsOf: file))
                if let preset = agents.firstIndex(where: { $0.id == agent.id }) {
                    agents[preset] = agent
                } else {
                    agents.append(agent)
                }
            } catch {
                problems.append(Problem(file: file.lastPathComponent, reason: String(describing: error)))
            }
        }
        return Loaded(agents: agents, problems: problems)
    }

    public func save(_ agent: AgentDefinition) throws {
        guard Self.isValidId(agent.id) else { throw Refusal.invalidId(agent.id) }
        if let key = agent.environment.keys.sorted().first(where: { Self.looksSecret($0) && !(agent.environment[$0] ?? "").isEmpty }) {
            throw Refusal.secretInEnvironment(key)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(agent).write(to: file(for: agent.id), options: .atomic)
    }

    /// Moves a saved agent's file to the Trash. For an overridden preset, the preset comes back.
    public func remove(id: String) throws {
        guard Self.isValidId(id) else { throw Refusal.invalidId(id) }
        let url = file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentPresets.all.contains { $0.id == id } ? Refusal.isPreset(id) : Refusal.notFound(id)
        }
        try trash(url)
    }

    /// Saves a copy of the agent `id` under a fresh id, named "<name> copy", and returns it.
    @discardableResult
    public func duplicate(id: String) throws -> AgentDefinition {
        let agents = try load().agents
        guard var copy = agents.first(where: { $0.id == id }) else { throw Refusal.notFound(id) }
        let taken = Set(agents.map(\.id))
        var fresh = "\(id)-copy", n = 1
        while taken.contains(fresh) {
            n += 1
            fresh = "\(id)-copy-\(n)"
        }
        copy.id = fresh
        copy.name += " copy"
        try save(copy)
        return copy
    }

    private func file(for id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// A variable name that usually carries a credential.
    static func looksSecret(_ name: String) -> Bool {
        name.range(of: "(API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)", options: [.regularExpression, .caseInsensitive]) != nil
    }
}
