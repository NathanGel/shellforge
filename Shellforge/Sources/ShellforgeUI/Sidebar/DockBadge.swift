// Ported from AiTerm (app/Sources/AiTermCore/Interface/DockBadge.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The Dock icon's badge: how many task and terminal rows wait on you — needing input, or done and
/// unseen — the rows Focus View shows. None at zero.
public enum DockBadge {
    public static func label(count: Int) -> String? { count > 0 ? String(count) : nil }

    /// Once for the app: a task's status is the helper's, the same in every window, and a terminal's
    /// comes from its tabs, which may be in any window — each row counts once however many show it.
    @MainActor
    public static func count(across sidebars: [SidebarModel]) -> Int {
        let tasks = Set(sidebars.flatMap(\.waitingOnYou))
        let terminals = Set(sidebars.flatMap(\.waitingTerminals))
        return tasks.count + terminals.count
    }
}
