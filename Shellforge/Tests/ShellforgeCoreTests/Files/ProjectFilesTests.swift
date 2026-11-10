import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct ProjectFilesTests {
    /// Writes `text` at `relative` under `root`, making the folders on the way.
    private func write(_ relative: String, in root: String, _ text: String = "x") throws {
        let url = URL(fileURLWithPath: root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A fresh folder that is no repository.
    private func plainFolder() throws -> String {
        let path = TestScratch.root.appendingPathComponent("shellforge-folder-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func paths(_ listing: ProjectFiles.Listing) -> [String]? {
        guard case .git(let paths) = listing else { return nil }
        return paths.sorted()
    }

    @Test func aRepositoryListsTrackedAndUntrackedNotIgnored() throws {
        let repo = try GitRepoFixture()
        try write(".gitignore", in: repo.path, "dist/\n")
        try write("src/app.ts", in: repo.path)
        try repo.git("add", ".gitignore", "src/app.ts")
        try repo.git("commit", "-q", "-m", "app")
        try write("notes.md", in: repo.path)
        try write("dist/out.js", in: repo.path)
        #expect(paths(ProjectFiles.list(repo.path, launcher: repo.launcher)) == [".gitignore", "notes.md", "src/app.ts"])
    }

    @Test func namesWithSpacesAndNewlinesSurvive() throws {
        let repo = try GitRepoFixture()
        try write("my notes.md", in: repo.path)
        try write("odd\nname.txt", in: repo.path)
        #expect(paths(ProjectFiles.list(repo.path, launcher: repo.launcher)) == ["my notes.md", "odd\nname.txt"])
    }

    @Test func worktreesAreNeverListed() throws {
        let repo = try GitRepoFixture()
        try write("README.md", in: repo.path)
        try write(".worktrees/abc-123/src/app.ts", in: repo.path)
        #expect(paths(ProjectFiles.list(repo.path, launcher: repo.launcher)) == ["README.md"])
    }

    @Test func aPlainFolderListsItsTopLevelWithoutDotFiles() throws {
        let folder = try plainFolder()
        try write("README.md", in: folder)
        try write(".env", in: folder)
        try write(".cache/x", in: folder)
        try write("src/app.ts", in: folder)
        let launcher = try GitRepoFixture().launcher
        #expect(ProjectFiles.list(folder, launcher: launcher) == .folder([
            FileNode(name: "src", path: "src", isFolder: true, children: nil),
            FileNode(name: "README.md", path: "README.md", isFolder: false, children: nil),
        ]))
    }

    @Test func childrenListOneFolderLazily() throws {
        let folder = try plainFolder()
        try write("src/app.ts", in: folder)
        try write("src/.hidden", in: folder)
        try write("src/lib/util.ts", in: folder)
        #expect(ProjectFiles.children(of: "src", in: folder) == [
            FileNode(name: "lib", path: "src/lib", isFolder: true, children: nil),
            FileNode(name: "app.ts", path: "src/app.ts", isFolder: false, children: nil),
        ])
    }

    @Test func aMissingFolderIsReported() throws {
        let gone = TestScratch.root.appendingPathComponent("shellforge-gone-\(UUID().uuidString)").path
        let launcher = try GitRepoFixture().launcher
        #expect(ProjectFiles.list(gone, launcher: launcher) == .missing)
    }

    @Test func anUnreadableFolderIsReported() throws {
        let folder = try plainFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder) }
        let launcher = try GitRepoFixture().launcher
        guard case .unreadable(let reason) = ProjectFiles.list(folder, launcher: launcher) else {
            Issue.record("expected .unreadable")
            return
        }
        #expect(!reason.isEmpty)
    }
}
