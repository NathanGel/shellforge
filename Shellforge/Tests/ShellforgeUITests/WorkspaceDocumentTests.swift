import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor
@Suite struct WorkspaceDocumentTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-doc-\(UUID().uuidString)")

    /// A workspace file that is there but cannot be read is not saved over: the document says so,
    /// naming the folder it reads from, and refuses every change.
    @Test(.disabled(if: getuid() == 0, "root reads a file with no permissions"))
    func anUnreadableWorkspaceIsNotSavedOver() throws {
        let store = WorkspaceStore(folder: folder)
        let project = Project(id: UUID(), name: "example", path: "/Users/me/example", addedAt: Date(timeIntervalSince1970: 1_000))
        try store.save(Workspace(projects: [project], tasks: []))
        let file = folder.appendingPathComponent("workspace.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        let document = WorkspaceDocument(store: store)
        let shown = (folder.path as NSString).abbreviatingWithTildeInPath
        #expect(document.loadProblem?.contains(shown) == true)
        #expect(document.workspace == Workspace())
        #expect {
            try document.update { $0.projects.append(project) }
        } throws: { error in
            (error as? WorkspaceDocument.Refusal)?.description.contains(shown) == true
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #expect(try store.load().workspace.projects == [project])
    }
}
