// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/ClaudeDriver.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Claude Code's hooks: HTTP hooks for its lifecycle events and the status-line shim that carries
/// its usage, merged into `~/.claude/settings.json` beside whatever else is there (Emdash's hooks,
/// the user's own status line).
struct ClaudeHooks: HookDriver {
    static let settingsPath = ".claude/settings.json"
    /// The daemon's route for Claude Code's hooks (`shellforged` README).
    static let endpoint = "/hook/claude"

    let home: URL, port: Int, shimPath: String

    var settings: UserConfigFile { UserConfigFile(home: home, Self.settingsPath) }

    func probe() -> HookProbe {
        let file = settings
        switch file.read() {
        case .missing: return HookProbe(.missing)
        case .refused(let reason): return .refused(file, reason)
        case .present(let data):
            let object: [String: Any]
            do { object = try ClaudeSettings.mergeable(data) } catch { return .refused(file, error.reason) }
            // The status-line shim posts to the port in its file, so settings that are current beside
            // another port, or none, are outdated: Repair writes it.
            if ClaudeSettings.isInstalled(object, daemonPort: port, shimPath: shimPath),
               ShimPort.isRecorded(port, home: home) {
                return HookProbe(.current)
            }
            return HookProbe(ClaudeSettings.isOwned(object, shimPath: shimPath) ? .outdated : .missing)
        }
    }

    func install() throws {
        let file = settings
        let data: Data?
        switch file.read() {
        case .missing: data = nil
        case .refused(let reason): throw file.refusal(reason)
        case .present(let contents): data = contents
        }
        let result: (Data, originalStatusLine: [String: Any]?)
        do {
            result = try ClaudeSettings.merge(data, hookURL: "http://127.0.0.1:\(port)" + Self.endpoint, shimPath: shimPath)
        } catch let refusal as ClaudeSettings.Unmergeable {
            throw file.refusal(refusal.reason)
        }
        let (merged, original) = result
        // The shim's port and the user's own status line are on disk before `settings.json` points
        // Claude at the shim: a crash or a failed write between the two can never leave it running
        // a shim that posts nowhere, or without the status line it replaced.
        try ShimPort.record(port, home: home)
        try StatusLineOriginal.record(before(original: original, data: data),
                                      command: ShellforgePaths.statusLineOriginalURL(home: home))
        guard !ClaudeSettings.same(data, merged) else { return }
        try file.backUp()
        try file.write(merged)
    }

    /// The status line the file had: the user's own command when the merge set one aside, ours when
    /// `settings.json` still names our shim, whether or not it can run (the question is what the
    /// file says, not whether that shim works: a moved bundle would otherwise look like the user
    /// removing our status line, and the record of their real one would go), otherwise none.
    private func before(original: [String: Any]?, data: Data?) -> StatusLineOriginal.Before {
        if let command = original?["command"] as? String, !command.isEmpty { return .foreign(command) }
        if original == nil, ClaudeSettings.statusLineIsInstalled(data, shimPath: shimPath, isRunnable: { _ in true }) { return .ours }
        return .missing
    }

}
