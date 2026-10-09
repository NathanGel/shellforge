// Ported from AiTerm (app/Sources/AiTermCore/Sidebar/SidebarModel.swift: AvatarGroup, BranchLabel),
// GPLv3, Laurens D'Hondt.
import ShellforgeCore

/// A row's agent marks: the first few, and how many more there are.
public struct AvatarGroup: Equatable, Sendable { public var marks: [SessionAgent]; public var overflow: Int }

/// A row's branch line (design canvas, "Branch awareness · 17 Sep"): the branch of the tab you are
/// looking at, how many *other* branches the same window has open, and whether that branch is not
/// the one the row is bound to. `detail` is the hover text; it is empty when there is nothing to
/// explain.
public struct BranchLabel: Equatable, Sendable {
    public var name: String, extra: Int, drifted: Bool, detail: String
    public init(name: String, extra: Int, drifted: Bool, detail: String) {
        self.name = name; self.extra = extra; self.drifted = drifted; self.detail = detail
    }
    public static let none = BranchLabel(name: "", extra: 0, drifted: false, detail: "")
}
