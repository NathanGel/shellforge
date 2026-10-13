// Ported from AiTerm (app/Sources/AiTerm/SheetKind.swift: RenameTarget's copy), GPLv3, Laurens D'Hondt.
import Foundation

/// What a Rename sheet says, per kind of row: AiTerm's words. A review is a task to it, and says so.
public struct RenameCopy: Equatable, Sendable {
    public let title: String
    public let field: String
    /// The band's one sentence: what the new name changes, and what keeps its own.
    public let subtitle: String

    public static let task = RenameCopy(title: "Rename task", field: "Task name", subtitle: "The branch and worktree keep their names.")
    /// A terminal's tabs are titled with its name as they open, and keep that title.
    public static let terminal = RenameCopy(title: "Rename terminal", field: "Terminal name",
                                            subtitle: "Renames the row in the sidebar; its iTerm2 tabs keep their titles.")
    public static let divider = RenameCopy(title: "Rename divider", field: "Divider name",
                                           subtitle: "Changes the heading over the projects under it.")
}
