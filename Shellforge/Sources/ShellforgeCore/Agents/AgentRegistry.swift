import Foundation

/// The agents a task can start: the built-ins, the ready-made agents the app ships, then every
/// agent saved in `folder`, one JSON file each — `~/Library/Application Support/Shellforge/agents/`
/// by default — so a set of agents can be copied to another Mac. A saved agent with a built-in's or
/// a ready-made agent's id replaces it.
public struct AgentRegistry: Sendable {
    public let folder: URL
    /// The folder of the ready-made agents' files, inside the app. Nil when there is none.
    public let readyMade: URL?
    private let trash: @Sendable (URL) throws -> Void

    /// `trash` disposes of a removed agent's file; the default moves it to the user's Trash, so a
    /// removal can be undone from Finder.
    public init(folder: URL = AgentRegistry.defaultFolder, readyMade: URL? = nil,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.folder = folder
        self.readyMade = readyMade
        self.trash = trash
    }

    /// Where an agent comes from. An override keeps the origin of what it replaces.
    public enum Origin: Equatable, Sendable {
        case builtIn, readyMade, own
    }

    /// The ready-made agents' folder inside an app's resources: `<resources>/hooks/agents`.
    public static func bundledReadyMade(resourceURL: URL?) -> URL? {
        resourceURL?.appendingPathComponent("hooks/agents", isDirectory: true)
    }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellforge/agents", isDirectory: true)
    }

    public struct Loaded: Equatable, Sendable {
        public var agents: [AgentDefinition]
        /// Files that could not be read; the other agents load regardless.
        public var problems: [Problem]
        public var origins: [String: Origin] = [:]
        /// The built-ins and ready-made agents a saved file replaces: Restore Default removes it.
        public var overridden: Set<String> = []
    }

    public struct Problem: Equatable, Sendable {
        public var file: String
        public var reason: String
    }

    public enum Refusal: Error, Equatable {
        /// A preset that was never overridden has no file to remove.
        case isPreset(String)
        /// A ready-made agent that was never overridden has no file to remove.
        case isReadyMade(String)
        /// A new agent of the person's own can't take a built-in's id, or `shell`.
        case reservedId(String)
        /// A new agent can't take the id of one that already has a file, or a ready-made agent.
        case idTaken(String)
        /// The agent's file isn't JSON Shellforge can read, so a save would throw away what it holds.
        case unreadableFile(String)
        case notFound(String)
        /// An id is a file name: letters, digits, `-` and `_` only.
        case invalidId(String)
        /// A key or token typed as a plain environment variable; it belongs in `secrets`, as a
        /// Keychain reference, so it is never written to disk.
        case secretInEnvironment(String)
    }

    private func jsonFiles(in folder: URL?) -> [URL] {
        guard let folder else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.deletingPathExtension().lastPathComponent < $1.deletingPathExtension().lastPathComponent }
    }

    public func load() throws -> Loaded {
        var loaded = Loaded(agents: AgentPresets.all, problems: [])
        for agent in AgentPresets.all { loaded.origins[agent.id] = .builtIn }
        func place(_ agent: AgentDefinition, as origin: Origin) {
            if let i = loaded.agents.firstIndex(where: { $0.id == agent.id }) {
                loaded.agents[i] = agent
                loaded.overridden.insert(agent.id)
            } else {
                loaded.agents.append(agent)
                loaded.origins[agent.id] = origin
            }
        }
        for file in jsonFiles(in: readyMade) {
            do {
                let agent = try JSONDecoder().decode(AgentDefinition.self, from: Data(contentsOf: file))
                // A built-in's id is never a ready-made agent's, and the first file with an id has it.
                guard !AgentPresets.isBuiltIn(agent.id), loaded.origins[agent.id] == nil else { continue }
                place(agent, as: .readyMade)
            } catch {
                loaded.problems.append(Problem(file: file.lastPathComponent, reason: String(describing: error)))
            }
        }
        for file in jsonFiles(in: folder) {
            do {
                let agent = try JSONDecoder().decode(AgentDefinition.self, from: Data(contentsOf: file))
                // `shell` is the plain terminal, no agent: a file claiming it is left out.
                guard agent.id != "shell" else { continue }
                place(agent, as: .own)
            } catch {
                loaded.problems.append(Problem(file: file.lastPathComponent, reason: String(describing: error)))
            }
        }
        return loaded
    }

    /// Saves a new agent of the person's own. Its id can't be a built-in's or `shell`, or one that
    /// has a file or is a ready-made agent's: editing those is `save`, which makes an override.
    public func create(_ agent: AgentDefinition, secrets: any SecretStore) throws {
        guard !AgentPresets.reservedIds.contains(agent.id) else { throw Refusal.reservedId(agent.id) }
        guard Self.isValidId(agent.id) else { throw Refusal.invalidId(agent.id) }
        guard !FileManager.default.fileExists(atPath: file(for: agent.id).path), !readyMadeIds().contains(agent.id) else {
            throw Refusal.idTaken(agent.id)
        }
        try save(agent, secrets: secrets)
    }

    private func readyMadeIds() -> Set<String> {
        Set(jsonFiles(in: readyMade).compactMap { (try? JSONDecoder().decode(AgentDefinition.self, from: Data(contentsOf: $0)))?.id })
    }

    /// What a file holds as JSON, nil when there is no file, and an error when it isn't an object.
    private func fields(of url: URL, id: String) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Refusal.unreadableFile(id)
        }
        return object
    }

    /// The variables an agent's file names as secrets, from the JSON itself so a file that no
    /// longer decodes still gives them.
    private func secretNames(_ fields: [String: Any]?) -> Set<String> {
        Set((fields?["secrets"] as? [String: Any])?.keys.map { $0 } ?? [])
    }

    /// Writes the agent's file. A file already there keeps every key the agent doesn't know,
    /// whatever its value, and loses the ones the agent no longer has (a cleared default reasoning).
    /// A secret the file named and the agent no longer does is deleted from `secrets`. A file that
    /// isn't JSON is refused, not written over.
    public func save(_ agent: AgentDefinition, secrets: any SecretStore) throws {
        guard Self.isValidId(agent.id) else { throw Refusal.invalidId(agent.id) }
        // `shell` is no built-in agent to override.
        guard AgentPresets.isBuiltIn(agent.id) || !AgentPresets.reservedIds.contains(agent.id) else { throw Refusal.reservedId(agent.id) }
        if let key = agent.environment.keys.sorted().first(where: { Self.looksSecret($0) && !(agent.environment[$0] ?? "").isEmpty }) {
            throw Refusal.secretInEnvironment(key)
        }
        let url = file(for: agent.id)
        let existing = try fields(of: url, id: agent.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var merged = existing ?? [:]
        for key in AgentDefinition.CodingKeys.allCases.map(\.rawValue) { merged[key] = nil }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any] ?? [:]
        merged.merge(encoded) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        for variable in secretNames(existing).subtracting(agent.secrets.keys) {
            secrets.set(AgentSecrets.key(agent: agent.id, variable: variable), nil)
        }
    }

    /// Moves a saved agent's file to the Trash and deletes the Keychain items the file names, even
    /// if it no longer decodes. For an overridden built-in or ready-made agent, the original comes back.
    public func remove(id: String, secrets: any SecretStore) throws {
        guard Self.isValidId(id) else { throw Refusal.invalidId(id) }
        let url = file(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if AgentPresets.isBuiltIn(id) { throw Refusal.isPreset(id) }
            if readyMadeIds().contains(id) { throw Refusal.isReadyMade(id) }
            throw Refusal.notFound(id)
        }
        let names = secretNames(try? fields(of: url, id: id))
        try trash(url)
        for variable in names { secrets.set(AgentSecrets.key(agent: id, variable: variable), nil) }
    }

    /// Saves a copy of the agent `id` under a fresh id, named "<name> copy", and returns it. The copy
    /// is the person's own, and detected as an agent of theirs is: automatically.
    @discardableResult
    public func duplicate(id: String, secrets: any SecretStore) throws -> AgentDefinition {
        let agents = try load().agents
        guard var copy = agents.first(where: { $0.id == id }) else { throw Refusal.notFound(id) }
        let taken = Set(agents.map(\.id))
        var fresh = "\(id)-copy", n = 1
        while taken.contains(fresh) {
            n += 1
            fresh = "\(id)-copy-\(n)"
        }
        // An item the form wrote for the original goes with the original: the copy names its own,
        // which `AgentListModel.duplicate` fills. An item a hand-written file names is kept as it is.
        copy.secrets = copy.secrets.reduce(into: [:]) { out, entry in
            out[entry.key] = entry.value == AgentSecrets.key(agent: id, variable: entry.key)
                ? AgentSecrets.key(agent: fresh, variable: entry.key) : entry.value
        }
        copy.id = fresh
        copy.name += " copy"
        // A built-in's detection is keyed by its id, which the copy doesn't have.
        if case .preset = copy.status { copy.status = .terminal }
        try save(copy, secrets: secrets)
        return copy
    }

    /// An id for a new agent named `name`: its lowercase letters and digits, runs of anything else
    /// as one `-`, then `-2`, `-3`… while `taken`, or a reserved id, has it.
    public static func freshId(for name: String, taken: Set<String>) -> String {
        var base = name.lowercased().unicodeScalars.reduce(into: "") { out, scalar in
            let plain = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
            if plain { out.unicodeScalars.append(scalar) } else if !out.hasSuffix("-") { out += "-" }
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "agent" }
        let unavailable = taken.union(AgentPresets.reservedIds)
        var fresh = base, n = 1
        while unavailable.contains(fresh) {
            n += 1
            fresh = "\(base)-\(n)"
        }
        return fresh
    }

    private func file(for id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    static func isValidId(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    /// A variable name that usually carries a credential.
    public static func looksSecret(_ name: String) -> Bool {
        name.range(of: "(API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

extension AgentRegistry.Refusal: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .reservedId(let id): "“\(id)” is reserved for Shellforge’s built-in agents, so an agent of your own can’t use it. Choose another name."
        case .isPreset(let id): "“\(id)” is built in, so there is no file to remove."
        case .isReadyMade(let id): "“\(id)” is ready-made, so there is no file to remove."
        case .notFound(let id): "There is no agent “\(id)”."
        case .invalidId(let id): "“\(id)” can’t be an agent id. Use letters, digits, - and _, up to 64 characters."
        case .idTaken(let id): "There is already an agent “\(id)”. Choose another name."
        case .unreadableFile(let id): "The file for “\(id)” isn’t valid JSON, so Shellforge won’t write over it. Fix or move it first."
        case .secretInEnvironment(let name): "\(name) looks like a secret. Keep it as a secret, not a plain environment variable."
        }
    }
}
