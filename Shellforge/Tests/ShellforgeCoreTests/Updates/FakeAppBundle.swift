// Ported from AiTerm (app/Tests/AiTermCoreTests/Support/FakeAppBundle.swift), GPLv3, Laurens D'Hondt.
import Foundation
@testable import ShellforgeCore

/// A minimal ad-hoc-signed app — an Info.plist and a shell-script executable — so staging can be
/// tested against real `hdiutil`, `ditto` and `codesign` without building Shellforge.
enum FakeAppBundle {
    static func make(in folder: URL, name: String = "Shellforge.app", identifier: String = "com.test.shellforge",
                     version: String = "0.3.0") throws -> URL {
        let app = folder.appendingPathComponent(name)
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("Shellforge")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Shellforge",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    /// A disk image whose volume holds what `folder` holds — the app itself, for the usual case.
    static func dmg(of folder: URL, to dmg: URL) throws {
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-ov", "-fs", "HFS+", "-format", "UDZO", "-volname", "Shellforge",
                                     "-srcfolder", folder.path, dmg.path], timeout: 120)
    }

    /// Marks `url` — and, for a folder, everything in it — as downloaded, as a browser or
    /// URLSession download would.
    static func quarantine(_ url: URL) throws {
        try run("/usr/bin/xattr", ["-w", "-r", "com.apple.quarantine", "0081;00000000;Shellforge;", url.path])
    }

    /// Whether anything in `url` carries the quarantine attribute.
    static func isQuarantined(_ url: URL) -> Bool {
        let out = try? ChildProcess.run("/usr/bin/xattr", ["-r", "-l", url.path], environment: ProcessInfo.processInfo.environment, timeout: 30)
        return out?.stdout.contains("com.apple.quarantine") ?? false
    }

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 30) throws {
        let output = try ChildProcess.run(tool, arguments, environment: ProcessInfo.processInfo.environment, timeout: timeout)
        guard output.status == 0 else {
            throw NSError(domain: "FakeAppBundle", code: Int(output.status), userInfo: [NSLocalizedDescriptionKey: output.stderr])
        }
    }
}
