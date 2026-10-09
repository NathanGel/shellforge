import Combine
import Foundation
import ShellforgeCore

/// The one workspace every window's sidebar shows. Each window keeping its own copy would let the
/// last window to save drop what another added, so there is one document, and every change goes
/// through it: applied to a copy, saved, and only then shown.
@MainActor
public final class WorkspaceDocument: ObservableObject {
    @Published public private(set) var workspace: Workspace
    /// What went wrong loading the workspace, in words for the sidebar; nil when it loaded cleanly.
    public let loadProblem: String?

    private let store: WorkspaceStore
    /// False when the file could not be read or set aside: saving would overwrite the user's data.
    private let canSave: Bool

    public enum Refusal: Error, CustomStringConvertible {
        case notLoaded

        public var description: String {
            "Your workspace file could not be read, so changes are not saved over it. Quit Shellforge and check ~/Library/Application Support/Shellforge."
        }
    }

    public init(store: WorkspaceStore) {
        self.store = store
        do {
            let loaded = try store.load()
            workspace = loaded.workspace
            canSave = true
            loadProblem = loaded.recoveredFrom.map {
                "Your workspace file was damaged. It was kept as \($0), and the last good copy was restored."
            }
        } catch {
            workspace = Workspace()
            canSave = false
            loadProblem = Refusal.notLoaded.description
        }
    }

    /// Applies `change` to a copy of the workspace, saves the copy, and only then shows it, so the
    /// sidebar never shows what is not on disk.
    public func update(_ change: (inout Workspace) throws -> Void) throws {
        guard canSave else { throw Refusal.notLoaded }
        var next = workspace
        try change(&next)
        try store.save(next)
        workspace = next
    }
}
