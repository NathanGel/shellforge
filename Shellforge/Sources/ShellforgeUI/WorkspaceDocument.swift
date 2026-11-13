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

    /// The one window rearranging the sidebar, if any. Weak and in memory only: closing that window
    /// frees the lock.
    public weak var rearranger: SidebarModel?

    private let store: WorkspaceStore
    /// False when the file could not be read or set aside: saving would overwrite the user's data.
    private let canSave: Bool

    public enum Refusal: Error, CustomStringConvertible {
        /// `folder` is the running build's data folder, where its `workspace.json` is.
        case notLoaded(folder: String)

        public var description: String {
            switch self {
            case .notLoaded(let folder):
                "Your workspace file could not be read, so changes are not saved over it. Quit Shellforge and check \(folder)."
            }
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
            if let loadProblem { ErrorLogging.record("workspace", loadProblem) }
        } catch {
            workspace = Workspace()
            canSave = false
            loadProblem = Refusal.notLoaded(folder: Self.shown(store.folder)).description
            ErrorLogging.record("workspace", "Loading the workspace failed: \(error)")
        }
    }

    /// The folder as the person would type it, with `~` for their home.
    private static func shown(_ folder: URL) -> String {
        (folder.path as NSString).abbreviatingWithTildeInPath
    }

    /// Applies `change` to a copy of the workspace, saves the copy, and only then shows it, so the
    /// sidebar never shows what is not on disk.
    public func update(_ change: (inout Workspace) throws -> Void) throws {
        guard canSave else { throw Refusal.notLoaded(folder: Self.shown(store.folder)) }
        var next = workspace
        try change(&next)
        do { try store.save(next) } catch {
            ErrorLogging.record("workspace", "Saving the workspace failed: \(error)")
            throw error
        }
        workspace = next
    }
}
