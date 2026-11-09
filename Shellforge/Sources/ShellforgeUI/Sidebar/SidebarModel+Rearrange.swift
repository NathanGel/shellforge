import Foundation
import ShellforgeCore

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
        endDrag()
        if document.rearranger === self { document.rearranger = nil }
    }
}

// -- dragging -------------------------------------------------------------------

extension SidebarModel {
    /// A row is picked up: a project folds to its header until it is dropped.
    public func startDragging(_ item: RearrangeDraft.Item) {
        guard isRearranging else { return }
        draggedItem = item
        dropTarget = nil
        if case .entry(.project(let id)) = item { draggingProject = id } else { draggingProject = nil }
    }

    /// The drag is over `item`'s upper or lower half: the line is drawn there when the draft would
    /// take the drop, and none when it would refuse it. True when it would take it.
    @discardableResult
    public func hover(over item: RearrangeDraft.Item, lowerHalf: Bool) -> Bool {
        guard landing(on: item, lowerHalf: lowerHalf) != nil else {
            if dropTarget != nil { dropTarget = nil }
            return false
        }
        let target = RearrangeDropTarget(item: item, lowerHalf: lowerHalf)
        if dropTarget != target { dropTarget = target }
        return true
    }

    /// The dragged row is dropped on `item`'s upper or lower half: moved in the draft when it may be.
    /// The drag is over either way.
    @discardableResult
    public func drop(on item: RearrangeDraft.Item, lowerHalf: Bool) -> Bool {
        defer { endDrag() }
        guard let dragged = draggedItem, let before = landing(on: item, lowerHalf: lowerHalf) else { return false }
        return moveInDraft(dragged, before: before)
    }

    /// The drag ended without a drop here: nothing is dragged, no line is drawn.
    public func endDrag() {
        draggedItem = nil
        if draggingProject != nil { draggingProject = nil }
        if dropTarget != nil { dropTarget = nil }
    }

    /// Where dropping the dragged row on `item` would put it (`.some(nil)` = the end of its list), or nil when refused.
    private func landing(on item: RearrangeDraft.Item, lowerHalf: Bool) -> RearrangeDraft.Item?? {
        guard let dragged = draggedItem, let draft = rearrange else { return nil }
        return RearrangeDrop.landing(of: dragged, on: item, lowerHalf: lowerHalf, in: rows, draft: draft)
    }
}
