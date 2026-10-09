// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/GrokModelCatalog.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Grok Build's models, from the catalogue it caches at `~/.grok/models_cache.json` — the list its
/// own `/model` picker shows, read from disk so a probe starts no process. `[models]` in
/// `~/.grok/config.toml` names the default model and reasoning effort.
enum GrokModelCatalog {
    static func models(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [AgentModel] {
        models(modelsCacheJSON: try? Data(contentsOf: home.appendingPathComponent(".grok/models_cache.json")),
               configTOML: try? String(contentsOf: home.appendingPathComponent(".grok/config.toml"), encoding: .utf8))
    }

    /// The files `models(home:)` reads.
    static func sources(home: URL) -> [String] {
        [home.appendingPathComponent(".grok/models_cache.json").path, home.appendingPathComponent(".grok/config.toml").path]
    }

    static func models(modelsCacheJSON: Data?, configTOML: String?) -> [AgentModel] {
        guard let data = modelsCacheJSON,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["models"] as? [String: Any] else { return [] }
        let raw = String(decoding: data, as: UTF8.self)
        let config = TOMLStatements.tables(configTOML ?? "").first { $0.path == ["models"] }?.values ?? [:]
        let preferredEffort = config["default_reasoning_effort"]

        var models: [(offset: Int, model: AgentModel)] = entries.compactMap { key, value in
            guard let info = (value as? [String: Any])?["info"] as? [String: Any],
                  info["hidden"] as? Bool != true else { return nil }
            let id = (info["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            let levels = (info["reasoning_efforts"] as? [[String: Any]]) ?? []
            let supported = info["supports_reasoning_effort"] as? Bool ?? !levels.isEmpty
            // Grok lists the strongest first; the other pickers read weakest to strongest.
            let efforts: [String] = supported ? Array(levels.compactMap { $0["value"] as? String }.reversed()) : []
            let marked = levels.first { $0["default"] as? Bool == true }?["value"] as? String
            let own = marked ?? (info["reasoning_effort"] as? String) ?? AgentPresets.grok.defaultReasoning!
            let defaultEffort: String? = efforts.isEmpty ? nil
                : (preferredEffort.flatMap { efforts.contains($0) ? $0 : nil } ?? (efforts.contains(own) ? own : efforts.last))
            let model = AgentModel(id: id, label: (info["name"] as? String) ?? id,
                                   detail: info["description"] as? String,
                                   efforts: efforts, defaultEffort: defaultEffort)
            // JSONSerialization forgets key order; the key's position in the file restores it.
            let offset = raw.range(of: "\"\(key)\":")?.lowerBound.utf16Offset(in: raw) ?? Int.max
            return (offset, model)
        }
        models.sort { $0.offset < $1.offset }
        var ordered = models.map(\.model)
        if let preferred = config["default"], let index = ordered.firstIndex(where: { $0.id == preferred }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        return ordered
    }
}
