// Ported from AiTerm (app/Tests/AiTermCoreTests/UpdateStagerTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// Real `hdiutil`, `ditto` and `codesign`, which block: one test at a time.
@Suite(.serialized) struct UpdateStagerTests {
    let version = ReleaseVersion("0.3.0")!
    let stager = UpdateStager(expectedIdentifier: "com.test.shellforge", requirement: #"identifier "com.test.shellforge""#)

    func workspace() throws -> URL {
        let dir = TestScratch.root.appendingPathComponent("stager-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        return dir
    }

    func image(_ dir: URL, name: String = "Shellforge.app", identifier: String = "com.test.shellforge", version: String = "0.3.0") throws -> URL {
        _ = try FakeAppBundle.make(in: dir.appendingPathComponent("src"), name: name, identifier: identifier, version: version)
        let dmg = dir.appendingPathComponent("Shellforge-\(version).dmg")
        try FakeAppBundle.dmg(of: dir.appendingPathComponent("src"), to: dmg)
        return dmg
    }

    /// Whatever happens, nothing stays mounted from this test's folder, and `Updates/` holds at
    /// most the staged version.
    func expectNothingLeft(in dir: URL, keeping kept: [String] = []) throws {
        let info = try ChildProcess.run("/usr/bin/hdiutil", ["info"], environment: ProcessInfo.processInfo.environment, timeout: 30)
        #expect(!info.stdout.contains(dir.path), "a volume is still mounted under \(dir.path)")
        let updates = dir.appendingPathComponent("Updates")
        let left = (try? FileManager.default.contentsOfDirectory(atPath: updates.path)) ?? []
        #expect(left.sorted() == kept.sorted(), "Updates/ holds \(left)")
    }

    @Test func stagesAVerifiedApp() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try stager.stage(dmg: try image(dir), version: version, in: dir.appendingPathComponent("Updates"))
        #expect(staged.path == dir.appendingPathComponent("Updates/0.3.0/Shellforge.app").path)
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path))
        try expectNothingLeft(in: dir, keeping: ["0.3.0"])
    }

    /// A downloaded image is quarantined, and its app with it: staged, the app carries no
    /// quarantine, so the relaunch after the swap is not refused or questioned.
    @Test func theStagedAppCarriesNoQuarantine() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = try image(dir)
        try FakeAppBundle.quarantine(dir.appendingPathComponent("src/Shellforge.app"))
        try FakeAppBundle.dmg(of: dir.appendingPathComponent("src"), to: dmg)
        try FakeAppBundle.quarantine(dmg)
        let staged = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates"))
        #expect(!FakeAppBundle.isQuarantined(staged), "the staged app is still quarantined")
        try expectNothingLeft(in: dir, keeping: ["0.3.0"])
    }

    /// The app's own name in the image is not what is trusted — its identifier, version and
    /// signature are — so an image of iTerm2's product name, `iTerm2.app`, stages as well.
    @Test func stagesTheImagesOneAppWhateverItsName() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let staged = try stager.stage(dmg: try image(dir, name: "iTerm2.app"), version: version, in: dir.appendingPathComponent("Updates"))
        #expect(staged.path == dir.appendingPathComponent("Updates/0.3.0/Shellforge.app").path)
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path))
    }

    /// Two apps on the image: which one is the release is not for the stager to guess.
    @Test func rejectsAnImageWithTwoApps() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try FakeAppBundle.make(in: dir.appendingPathComponent("src"), name: "Other.app")
        let dmg = try image(dir)
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    @Test func rejectsWrongIdentifier() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = try image(dir, identifier: "com.googlecode.iterm2")
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    @Test func rejectsVersionThatIsNotTheRelease() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = try image(dir, version: "0.2.9")
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    /// The running app is certificate-signed; an ad-hoc app cannot satisfy its requirement.
    @Test func rejectsAppNotSignedByTheSameCertificate() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let strict = UpdateStager(expectedIdentifier: "com.test.shellforge",
                                  requirement: #"identifier "com.test.shellforge" and certificate leaf = H"0000000000000000000000000000000000000000""#)
        #expect(throws: UpdateError.unverified) { _ = try strict.stage(dmg: try image(dir), version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    @Test func rejectsAnImageWithoutTheApp() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("hi".utf8).write(to: dir.appendingPathComponent("src/README.txt"))
        let dmg = dir.appendingPathComponent("Shellforge-0.3.0.dmg")
        try FakeAppBundle.dmg(of: dir.appendingPathComponent("src"), to: dmg)
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    /// A lost session or a captive portal answers with a 200 HTML page.
    @Test func rejectsADownloadThatIsNotAnImage() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let dmg = dir.appendingPathComponent("Shellforge-0.3.0.dmg")
        try Data("<!DOCTYPE html><title>Sign in</title>".utf8).write(to: dmg)
        #expect(throws: UpdateError.unverified) { _ = try stager.stage(dmg: dmg, version: version, in: dir.appendingPathComponent("Updates")) }
        try expectNothingLeft(in: dir)
    }

    /// Leftovers from an earlier failed attempt at the same version are not trusted.
    @Test func startsFromACleanFolder() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let stale = dir.appendingPathComponent("Updates/0.3.0/Shellforge.app/Contents")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: stale.appendingPathComponent("leftover"))
        let staged = try stager.stage(dmg: try image(dir), version: version, in: dir.appendingPathComponent("Updates"))
        #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/leftover").path))
    }

    @Test func readsAnAdHocRequirement() throws {
        let dir = try workspace(); defer { try? FileManager.default.removeItem(at: dir) }
        let app = try FakeAppBundle.make(in: dir.appendingPathComponent("src"))
        #expect(try UpdateStager.designatedRequirement(of: app).hasPrefix(#"cdhash H""#))
    }
}
