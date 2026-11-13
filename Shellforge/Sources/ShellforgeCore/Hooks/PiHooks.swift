// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/PiDriver.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// PI's driver: an extension Shellforge owns outright in `~/.pi/agent/extensions/`, beside any other
/// tool's. It is Shellforge's when its first line carries the schema marker.
struct PiHooks: HookDriver {
    static let path = ".pi/agent/extensions/shellforge-status.ts"
    static let schemaVersion = 5
    private static let markerPrefix = "// Shellforge PI extension schema: "
    /// Where the bundled extension names the hook port, which Install fills in: a copy of the file
    /// in PI's home cannot read the app's constant, and one that named another port than the
    /// daemon's would post to nothing.
    static let portPlaceholder = "__SHELLFORGE_HOOK_PORT__"

    let home: URL
    let port: Int
    /// The bundled extension, with `portPlaceholder` where its port goes.
    let source: String

    /// What Install writes, and a current file matches exactly.
    private var installed: String { source.replacingOccurrences(of: Self.portPlaceholder, with: String(port)) }

    var file: UserConfigFile { UserConfigFile(home: home, Self.path) }

    /// A file that is there: foreign without the marker, outdated at another schema, and invalid
    /// when its marker is broken or, given the bundled `expected` source, its body differs.
    static func state(of text: String, expected: String?) -> HookState {
        guard let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init),
              firstLine.hasPrefix(markerPrefix) else { return .foreign }
        guard let version = Int(firstLine.dropFirst(markerPrefix.count)) else { return .invalidOwned }
        guard version == schemaVersion else { return .outdated }
        if let expected, text != expected { return .invalidOwned }
        return .current
    }

    func probe() -> HookProbe {
        let file = self.file
        switch file.readText() {
        case .missing: return HookProbe(.missing)
        case .refused(let reason): return .refused(file, reason)
        case .present(let text):
            var state = Self.state(of: text, expected: installed)
            // Written by Install for a daemon on another port: out of date, as an older schema is,
            // and mended by a Repair that writes this one's.
            if state == .invalidOwned, isInstalled(forSomePort: text) { state = .outdated }
            return state == .foreign ? .foreign(file) : HookProbe(state)
        }
    }

    /// Whether `text` is what Install writes, with some port's digits where `source` has its
    /// placeholder.
    private func isInstalled(forSomePort text: String) -> Bool {
        let pattern = #"\A"# + source.components(separatedBy: Self.portPlaceholder)
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[0-9]{1,5}") + #"\z"#
        // Every part of `source` is escaped, so the pattern always compiles.
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func install() throws {
        guard source.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
                == Self.markerPrefix + String(Self.schemaVersion) else {
            throw HookInstallError.invalidSource
        }
        let file = self.file
        switch file.readText() {
        case .refused(let reason): throw file.refusal(reason)
        case .present(let text) where Self.state(of: text, expected: nil) == .foreign:
            throw HookInstallError.foreign(path: file.displayPath)
        case .missing, .present: break
        }
        try file.write(Data(installed.utf8))
    }
}
