// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/CodexDriver.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Codex's hooks: command hooks for its lifecycle events and an MCP server for `Stop`, merged into
/// `~/.codex/config.toml` between marker comments, every other byte of the file kept.
struct CodexHooks: HookDriver {
    static let configPath = ".codex/config.toml"

    let home: URL, port: Int
    /// The support folder whose helper listens on `port`: its token goes into the hooks.
    let support: ShellforgeSupport

    var config: UserConfigFile { UserConfigFile(home: home, Self.configPath) }

    func probe() -> HookProbe { probe(auth: HookAuth.existing(in: support)) }

    func holdsTokenlessInstall() -> Bool { probe(auth: nil).state == .current }

    func postsWithoutToken() -> Bool {
        guard case .present(let text) = config.readText() else { return false }
        return CodexHookConfig.hasTokenlessHook(text, port: port)
    }

    private func probe(auth: HookAuth?) -> HookProbe {
        let file = config
        switch file.readText() {
        case .missing: return HookProbe(.missing)
        case .refused(let reason): return .refused(file, reason)
        case .present(let text):
            if let reason = Self.unmergeable(text) { return .refused(file, reason) }
            if CodexHookConfig.isInstalled(text, daemonPort: port, auth: auth) { return HookProbe(.current) }
            return HookProbe(CodexHookConfig.isOwned(text) ? .outdated : .missing)
        }
    }

    func install() throws {
        let file = config
        let text: String?
        switch file.readText() {
        case .missing: text = nil
        case .refused(let reason): throw file.refusal(reason)
        case .present(let contents): text = contents
        }
        if let text, let reason = Self.unmergeable(text) { throw file.refusal(reason) }
        let merged = CodexHookConfig.merge(text, hookURL: "http://127.0.0.1:\(port)", auth: try HookAuth.made(in: support))
        // The file holds the token: readable by its owner only, whether or not this merge changed it.
        guard merged != text else { return try file.makePrivate() }
        try file.backUp()
        try file.write(Data(merged.utf8), private: true)
    }


    /// Why Shellforge's `[[hooks.<event>]]` tables cannot be appended, when they cannot.
    private static func unmergeable(_ text: String) -> String? {
        if !TOMLStatements.isBalanced(text) { return "cannot be parsed" }
        return CodexHookConfig.conflict(in: text).map { "sets \($0) in a form Shellforge cannot merge" }
    }
}

extension CodexHooks {
    /// The installed app's support folder under `home`, as the tests' scratch homes have it.
    init(home: URL, port: Int) {
        self.init(home: home, port: port, support: .default(home: home))
    }
}
