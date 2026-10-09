// Ported from Shellforge (app/Sources/ShellforgeCore/Harnesses/UserConfigFile.swift), GPLv3, Laurens D'Hondt.
import Foundation
import os

let hooksLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "hooks")

/// Why a driver will not write: what the Settings card shows, through `localizedDescription`.
enum HookInstallError: Error, Equatable, LocalizedError {
    /// A file at the driver's own path that Shellforge did not write.
    case foreign(path: String)
    /// A file the driver must read before writing and cannot, or cannot merge into safely.
    /// `reason` finishes "it …": "cannot be read as text", "is not a JSON object".
    case refused(path: String, reason: String)
    /// The bundled PI extension does not carry the ownership marker it is checked by.
    case invalidSource

    var errorDescription: String? {
        switch self {
        case .foreign(let path): return "Refusing to replace \(path): Shellforge did not write it."
        case .refused(let path, let reason): return "Refusing to change \(path): it \(reason)."
        case .invalidSource: return "The bundled PI extension does not carry the current Shellforge ownership marker."
        }
    }
}

/// One file in the user's home that a driver reads and writes, handled the same way for every
/// harness. These files are often symlinks into a dotfiles repository, so every read and write
/// goes to the file the link names — an atomic write to the link itself would replace it with a
/// regular file — and a link that leads nowhere is refused, never replaced: that would discard
/// whatever it was meant to point at once its target reappears.
struct UserConfigFile: Sendable {
    /// What a read found. `refused` carries why, finishing "it …".
    enum Contents<Value> {
        case missing, present(Value), refused(String)

        var value: Value? {
            if case .present(let value) = self { return value }
            return nil
        }
    }

    let url: URL
    /// The path as the card names it, from the home: `~/.claude/settings.json`.
    let displayPath: String

    init(home: URL, _ path: String) {
        url = home.appendingPathComponent(path)
        displayPath = "~/" + path
    }

    /// The file the path names: the link's target when it is one.
    var target: URL { url.resolvingSymlinksInPath() }

    func refusal(_ reason: String) -> HookInstallError { .refused(path: displayPath, reason: reason) }

    func read() -> Contents<Data> {
        if let target = Self.danglingLinkTarget(url) { return .refused("links to \(target), which does not exist") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        guard !isDirectory.boolValue else { return .refused("cannot be read") }
        do { return .present(try Data(contentsOf: target)) }
        catch {
            hooksLog.error("Reading \(displayPath, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return .refused("cannot be read")
        }
    }

    /// The file as UTF-8 text, refused when it is not: merging "nothing" into it would replace
    /// the user's file with Shellforge's entries alone. A byte-order mark is not part of the text.
    func readText() -> Contents<String> {
        switch read() {
        case .missing: return .missing
        case .refused(let reason): return .refused(reason)
        case .present(let data):
            guard var text = String(data: data, encoding: .utf8) else { return .refused("cannot be read as text") }
            if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
            return .present(text)
        }
    }

    /// The one-time backup, kept beside the link: a copy of the file it names, not of the link.
    func backUp() throws {
        let fileManager = FileManager.default, file = target
        let backup = url.appendingPathExtension("shellforge-backup")
        if fileManager.fileExists(atPath: file.path), !fileManager.fileExists(atPath: backup.path) {
            try fileManager.copyItem(at: file, to: backup)
        }
    }

    /// Atomically, through the link, creating the directory it goes in.
    func write(_ data: Data) throws {
        if let target = Self.danglingLinkTarget(url) { throw refusal("links to \(target), which does not exist") }
        let file = target
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// Where `url` points when it is a symlink that leads nowhere. `fileExists` follows the link
    /// and calls that "missing", so the link itself is looked at first, without following it.
    static func danglingLinkTarget(_ url: URL) -> String? {
        let fileManager = FileManager.default
        guard (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink,
              !fileManager.fileExists(atPath: url.path) else { return nil }
        return (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) ?? "a missing file"
    }
}

extension UserConfigFile.Contents: Equatable where Value: Equatable {}
