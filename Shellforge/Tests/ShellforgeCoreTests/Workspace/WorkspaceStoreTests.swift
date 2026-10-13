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
}
