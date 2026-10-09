// Ported from AiTerm (app/Tests/AiTermCoreTests/UserConfigFileTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

/// The one way every driver reads and writes a file in the user's home.
@Suite struct UserConfigFileTests {
    let fm = FileManager.default

    func tempHome() throws -> URL {
        let home = fm.temporaryDirectory.appendingPathComponent("sf-ucf-\(UUID().uuidString)")
        try fm.createDirectory(at: home.appendingPathComponent(".tool"), withIntermediateDirectories: true)
        return home
    }

    @Test func readsWhatIsThereAndSaysWhyItCannot() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let file = UserConfigFile(home: home, ".tool/config")
        #expect(file.displayPath == "~/.tool/config")
        #expect(file.readText() == .missing)

        try Data("\u{FEFF}a = 1\n".utf8).write(to: file.url)
        #expect(file.readText() == .present("a = 1\n"))

        try Data([0x61, 0xE9]).write(to: file.url)
        #expect(file.read() == .present(Data([0x61, 0xE9])))
        #expect(file.readText() == .refused("cannot be read as text"))

        try fm.removeItem(at: file.url)
        try fm.createDirectory(at: file.url, withIntermediateDirectories: false)
        #expect(file.read() == .refused("cannot be read"))
    }

    @Test func aLinkToNothingIsRefusedAndNeverWritten() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let file = UserConfigFile(home: home, ".tool/config")
        let missing = home.appendingPathComponent("dotfiles/config")
        try fm.createSymbolicLink(at: file.url, withDestinationURL: missing)

        let reason = "links to \(missing.path), which does not exist"
        #expect(file.read() == .refused(reason))
        #expect(throws: HookInstallError.refused(path: "~/.tool/config", reason: reason)) { try file.write(Data("x".utf8)) }
        #expect(try fm.destinationOfSymbolicLink(atPath: file.url.path) == missing.path)
        #expect(!fm.fileExists(atPath: missing.path))
    }

    /// An atomic write replaces the file it names, so it keeps the link, and the target's mode.
    @Test func aWriteGoesThroughTheLinkAndKeepsTheMode() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let file = UserConfigFile(home: home, ".tool/config")
        let elsewhere = home.appendingPathComponent("dotfiles/config")
        try fm.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: elsewhere)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: elsewhere.path)
        try fm.createSymbolicLink(at: file.url, withDestinationURL: elsewhere)

        try file.write(Data("new".utf8))

        #expect(try fm.destinationOfSymbolicLink(atPath: file.url.path) == elsewhere.path)
        #expect(try Data(contentsOf: elsewhere) == Data("new".utf8))
        #expect((try fm.attributesOfItem(atPath: elsewhere.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func theBackupIsTakenOnceBesideTheLinkAndHoldsTheContent() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let file = UserConfigFile(home: home, ".tool/config")
        let elsewhere = home.appendingPathComponent("dotfiles/config")
        try fm.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("first".utf8).write(to: elsewhere)
        try fm.createSymbolicLink(at: file.url, withDestinationURL: elsewhere)

        try file.backUp()
        try file.write(Data("second".utf8))
        try file.backUp()

        let backup = file.url.appendingPathExtension("shellforge-backup")
        #expect(try fm.attributesOfItem(atPath: backup.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: backup) == Data("first".utf8))
    }

    @Test func writingCreatesTheDirectory() throws {
        let home = try tempHome(); defer { try? fm.removeItem(at: home) }
        let file = UserConfigFile(home: home, ".other/deep/config")
        try file.write(Data("x".utf8))
        #expect(file.read() == .present(Data("x".utf8)))
    }
}
