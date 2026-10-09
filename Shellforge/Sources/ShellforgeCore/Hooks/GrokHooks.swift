// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/GrokDriver.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Grok Build's driver: the hooks file and the status line, installed and checked together. The
/// hooks carry state; the status line carries context. A status line Shellforge must not touch leaves
/// the driver current but adds a failed Context check to the card.
struct GrokHooks: HookDriver {
    let home: URL, port: Int, shimPath: String

    var hooks: UserConfigFile { UserConfigFile(home: home, GrokHooksFile.path) }
    var config: UserConfigFile { UserConfigFile(home: home, GrokStatusLineConfig.path) }

    /// Both files, read once, and the hooks file's state when it is there.
    private struct Reading {
        var hooks: UserConfigFile.Contents<Data>
        var hooksState: HookState
        var config: UserConfigFile.Contents<String>
    }

    private func read() -> Reading {
        let contents = hooks.read()
        let state: HookState
        switch contents {
        case .missing: state = .missing
        case .refused: state = .unreadable
        case .present(let data): state = GrokHooksFile.state(of: data, port: port)
        }
        var text = config.readText()
        // A stray bracket would let the editor read the rest of the file as one statement, and
        // append a second `[ui.status_line]` beside the real one. Grok rejects such a file anyway.
        if case .present(let present) = text, !TOMLStatements.isBalanced(present) { text = .refused("cannot be parsed") }
        return Reading(hooks: contents, hooksState: state, config: text)
    }

    /// A hooks file Shellforge must not touch, or a config it cannot read, comes first — Install
    /// could only refuse — and the hooks file wins when both are unreadable.
    func probe() -> HookProbe {
        let reading = read()
        if case .refused(let reason) = reading.hooks { return .refused(hooks, reason) }
        if reading.hooksState == .foreign { return .foreign(hooks) }
        if case .refused(let reason) = reading.config { return .refused(config, reason) }
        guard reading.hooksState == .current else { return HookProbe(reading.hooksState) }
        switch GrokStatusLineConfig.state(reading.config.value, shimPath: shimPath) {
        // The shim posts to the port in its file; a status line pointed at it is outdated until
        // that is the daemon's, as Install makes it.
        case .current: return HookProbe(ShimPort.isRecorded(port, home: home) ? .current : .outdated)
        case .builtin:
            return HookProbe(state: .current, explanation: "Grok’s built-in status line is on, so Shellforge cannot read context.")
        case .unsupportedLayout:
            return HookProbe(state: .current, explanation: "Grok’s status line is set in a form Shellforge cannot edit, so Shellforge cannot read context.")
        case .missing, .outdated, .foreign: return HookProbe(.outdated)
        }
    }

    /// Validates both halves before writing either: never the hooks file written with the status
    /// line refused afterwards.
    func install() throws {
        let reading = read()
        if case .refused(let reason) = reading.hooks { throw hooks.refusal(reason) }
        if reading.hooksState == .foreign { throw HookInstallError.foreign(path: hooks.displayPath) }
        if case .refused(let reason) = reading.config { throw config.refusal(reason) }
        if reading.hooksState != .current { try hooks.write(GrokHooksFile.contents(port: port)) }
        try ShimPort.record(port, home: home)
        try GrokStatusLineConfig.install(reading.config.value, into: config,
                                         original: ShellforgePaths.grokStatusLineOriginalURL(home: home), shimPath: shimPath)
    }

}
