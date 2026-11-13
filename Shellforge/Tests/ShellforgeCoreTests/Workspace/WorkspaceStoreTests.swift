import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct WorkspaceStoreTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-ws-\(UUID().uuidString)")
    private var store: WorkspaceStore { WorkspaceStore(folder: folder) }

    private func sample() -> Workspace {
        let project = Project(id: UUID(), name: "aiterm", path: "/Users/me/aiterm", addedAt: Date(timeIntervalSince1970: 1_000))
        let task = TaskItem(id: UUID(), projectId: project.id, title: "Fix login", branch: "fix-login",
                            worktreePath: "/Users/me/aiterm/.worktrees/fix-login", baseBranch: "main",
                            createdAt: Date(timeIntervalSince1970: 2_000))
        return Workspace(projects: [project], tasks: [task])
    }

    @Test func withNoFileTheWorkspaceIsEmpty() throws {
        #expect(try store.load() == .init(workspace: Workspace(), recoveredFrom: nil))
    }

    @Test func whatIsSavedLoadsBack() throws {
        let saved = sample()
        try store.save(saved)
        #expect(try store.load().workspace == saved)
    }

    @Test func savingKeepsThePreviousSaveAsTheBackup() throws {
        let first = sample()
        try store.save(first)
        var second = first
        second.projects[0].name = "renamed"
        try store.save(second)
        let backup = try Data(contentsOf: folder.appendingPathComponent("workspace.json.backup"))
        #expect(try JSONDecoder.workspace.decode(Workspace.self, from: backup) == first)
    }

    @Test func aDamagedFileIsKeptAsideAndTheBackupLoads() throws {
        let saved = sample()
        try store.save(saved)
        try store.save(saved)   // the backup now holds `saved` too
        try "{ truncated".write(to: folder.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        let loaded = try store.load()
        #expect(loaded.workspace == saved)
        let kept = try #require(loaded.recoveredFrom)
        #expect(kept.hasPrefix("workspace.json.damaged-"))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(kept).path))
    }

    /// A recovery must last: the launch after it, or a second window, still finds the projects.
    @Test func afterARecoveryTheNextLoadStillHasTheWorkspace() throws {
        let saved = sample()
        try store.save(saved)
        try store.save(saved)
        try "{ truncated".write(to: folder.appendingPathComponent("workspace.json"), atomically: true, encoding: .utf8)
        _ = try store.load()
        #expect(try store.load() == .init(workspace: saved, recoveredFrom: nil))
    }

    @Test func aMissingFileWithABackupLoadsTheBackup() throws {
        let saved = sample()
        try store.save(saved)
        try store.save(saved)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("workspace.json"))
        #expect(try store.load().workspace == saved)
    }

    @Test func aTaskWhoseProjectIsMissingIsRefused() throws {
        var broken = sample()
        broken.projects = []
        #expect(throws: WorkspaceStore.Refusal.taskWithoutProject(broken.tasks[0].id)) { try store.save(broken) }
    }

    @Test func aRepeatedIdIsRefused() throws {
        var twice = sample()
        twice.projects.append(twice.projects[0])
        #expect(throws: WorkspaceStore.Refusal.duplicateId(twice.projects[0].id)) { try store.save(twice) }
    }

    // MARK: A file that is there but cannot be read

    private var file: URL { folder.appendingPathComponent("workspace.json") }
    private var backup: URL { folder.appendingPathComponent("workspace.json.backup") }

    /// Saves twice, so both the file and the backup exist, then takes every permission off the file.
    private func unreadableFileWithBackup() throws -> Workspace {
        let saved = sample()
        try store.save(saved)
        try store.save(saved)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        return saved
    }

    private func restorePermissions() {
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    }

    /// A file that is there but cannot be read is not a missing one: loading throws, so the
    /// document refuses to save over it, instead of loading the backup and later replacing it.
    @Test(.disabled(if: getuid() == 0, "root reads a file with no permissions"))
    func anUnreadableWorkspaceRefusesToSave() throws {
        _ = try unreadableFileWithBackup()
        defer { restorePermissions() }
        #expect(throws: (any Error).self) { try store.load() }
    }

    /// A save whose copy of the old file fails leaves the backup as it was; no temporary copy is
    /// left behind.
    @Test(.disabled(if: getuid() == 0, "root reads a file with no permissions"))
    func theBackupIsReplacedNotRemovedFirst() throws {
        let saved = try unreadableFileWithBackup()
        defer { restorePermissions() }
        var next = saved
        next.projects[0].name = "renamed"
        #expect(throws: (any Error).self) { try store.save(next) }
        let kept = try Data(contentsOf: backup)
        #expect(try JSONDecoder.workspace.decode(Workspace.self, from: kept) == saved)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["workspace.json", "workspace.json.backup"])
    }

    /// A rename that fails (here the backup is a folder with something in it) keeps the old backup
    /// and leaves no temporary copy.
    @Test func aFailedRenameKeepsTheOldBackup() throws {
        let saved = sample()
        try store.save(saved)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try "kept".write(to: backup.appendingPathComponent("inside"), atomically: true, encoding: .utf8)
        var next = saved
        next.projects[0].name = "renamed"
        #expect(throws: (any Error).self) { try store.save(next) }
        #expect(try String(contentsOf: backup.appendingPathComponent("inside"), encoding: .utf8) == "kept")
        #expect(try store.load().workspace == saved)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["workspace.json", "workspace.json.backup"])
    }

    /// A temporary backup left by a crash between its copy and its rename goes at the next load.
    /// Only regular files with exactly that name are removed.
    @Test func aLeftoverTemporaryBackupIsRemovedAtLoad() throws {
        try store.save(sample())
        let leftover = folder.appendingPathComponent("workspace.json.backup-0F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9.tmp")
        try "{}".write(to: leftover, atomically: true, encoding: .utf8)
        let notAUUID = folder.appendingPathComponent("workspace.json.backup-mine.tmp")
        try "invented".write(to: notAUUID, atomically: true, encoding: .utf8)
        let folderNamedLikeOne = folder.appendingPathComponent("workspace.json.backup-folder.tmp")
        try FileManager.default.createDirectory(at: folderNamedLikeOne, withIntermediateDirectories: true)
        let other = folder.appendingPathComponent("notes.tmp")
        try "invented".write(to: other, atomically: true, encoding: .utf8)
        _ = try store.load()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: folderNamedLikeOne.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: notAUUID.path), "only a UUID-named one is a temporary")
    }
}
