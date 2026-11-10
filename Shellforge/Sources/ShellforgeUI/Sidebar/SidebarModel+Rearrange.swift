import Foundation
import os
import ShellforgeCore

/// Each move and refusal in Rearrange mode, for finding where one goes wrong: `log stream --level info --predicate
/// 'subsystem == "io.github.nathangel.shellforge" AND category == "rearrange"'`.
let rearrangeLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "rearrange")

/// Rearrange mode: the sidebar's order is edited as a draft and written once, on Done.
extension SidebarModel {
    public var isRearranging: Bool { rearrange != nil }

    /// Only one window rearranges at a time, so two drafts never race to save.
    public var canRearrange: Bool {
        rearrange == nil && (document.rearranger == nil || document.rearranger === self)
    }

    public func beginRearrange() {
        guard canRearrange else { return }
        rearrange = RearrangeDraft(document.workspace)
        document.rearranger = self
    }

    /// Saves the draft's order. A failed save is said and leaves the mode open, so nothing is lost.
    public func finishRearrange() {
        guard let draft = rearrange else { return }
        var saved = false
        attempt {
            try document.update { draft.apply(to: &$0) }
            saved = true
        }
        if saved { leaveRearrange() }
    }

    public func cancelRearrange() {
        leaveRearrange()
    }

    @discardableResult
    public func moveInDraft(_ item: RearrangeDraft.Item, before: RearrangeDraft.Item?) -> Bool {
        rearrange?.move(item, before: before) ?? false
    }

    public func stepInDraft(_ item: RearrangeDraft.Item, up: Bool) {
        rearrange?.step(item, up: up)
    }

    private func leaveRearrange() {
        rearrange = nil
        if document.rearranger === self { document.rearranger = nil }
    }
}

// -- dragging -------------------------------------------------------------------

extension SidebarModel {
    /// The List's own move in the mode: the row at `source.first` dragged to `destination` (SwiftUI's
    /// onMove index into `rows`). Moved in the draft when it lands in the row's own list and the rules
    /// allow it; otherwise refused, and the List puts the row back. Nothing happens outside the mode.
    @discardableResult
    public func moveRows(from source: IndexSet, to destination: Int) -> Bool {
        guard isRearranging, let index = source.first else { return false }
        guard let landing = RearrangeDrop.landing(moving: index, to: destination, in: rows) else {
            rearrangeLog.info("move of row \(index) to \(destination) refused: no landing")
            return false
        }
        let moved = moveInDraft(landing.item, before: landing.before)
        rearrangeLog.info("move of \(String(describing: landing.item), privacy: .public) before \(String(describing: landing.before), privacy: .public): \(moved ? "moved" : "refused", privacy: .public)")
        return moved
    }
}
