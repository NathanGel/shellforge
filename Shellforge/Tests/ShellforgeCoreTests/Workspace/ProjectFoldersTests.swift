import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ProjectFoldersTests {
    @Test func aRepositoryBecomesAProjectNamedAfterItsFolder() throws {
        let repo = try GitRepoFixture()
        let project = try ProjectFolders.project(at: repo.path, in: Workspace(), launcher: repo.launcher)
        #expect(project.name == "repo")
        #expect(project.path == URL(fileURLWithPath: repo.path).resolvingSymlinksInPath().path)
    }

    @Test func aSubfolderBecomesItsRepository() throws {
        let repo = try GitRepoFixture()
        try FileManager.default.createDirectory(atPath: "\(repo.path)/src/app", withIntermediateDirectories: true)
        let project = try ProjectFolders.project(at: "\(repo.path)/src/app", in: Workspace(), launcher: repo.launcher)
        #expect(project.path == URL(fileURLWithPath: repo.path).resolvingSymlinksInPath().path)
    }

    @Test func aFolderOutsideGitIsRefused() throws {
        let repo = try GitRepoFixture()
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("plain-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        let refusal = try #require(throws: ProjectFolders.Refusal.self) {
            try ProjectFolders.project(at: plain, in: Workspace(), launcher: repo.launcher)
        }
        guard case .notARepository(let reason) = refusal else { Issue.record("wrong refusal"); return }
        #expect(reason.contains("not a git repository"))
    }

    @Test func aRepositoryAlreadyInTheWorkspaceIsRefused() throws {
        let repo = try GitRepoFixture()
        let first = try ProjectFolders.project(at: repo.path, in: Workspace(), launcher: repo.launcher)
        #expect(throws: ProjectFolders.Refusal.alreadyAdded(first.path)) {
            try ProjectFolders.project(at: repo.path, in: Workspace(projects: [first]), launcher: repo.launcher)
        }
    }
}
