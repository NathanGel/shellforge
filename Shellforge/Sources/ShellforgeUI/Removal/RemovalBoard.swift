import Combine
import Foundation
import ShellforgeCore

/// Every task's removal, for every window over one workspace: each window has a sidebar of its
/// own, and a Remove started in one must be the task's only Remove, its row saying so in all of
/// them. One board per `WorkspaceDocument`, held while the document lives.
@MainActor
final class RemovalBoard: ObservableObject {
    /// Each task row's removal: running, or why the last one stopped.
    @Published var removals: [UUID: RowRemoval] = [:]
    /// The tasks whose Remove is asking its first question.
    var asking: Set<UUID> = []
    /// How many tasks or reviews are being created in each project: a project is not removed under
    /// a create, whose task would land in a project that is gone.
    var creating: [UUID: Int] = [:]

    private static let boards = NSMapTable<WorkspaceDocument, RemovalBoard>.weakToStrongObjects()

    static func shared(for document: WorkspaceDocument) -> RemovalBoard {
        if let board = boards.object(forKey: document) { return board }
        let board = RemovalBoard()
        boards.setObject(board, forKey: document)
        return board
    }
}
