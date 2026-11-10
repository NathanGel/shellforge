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
    /// A row is picked up: a project folds to its header until the drag ends. Returns the drag's
    /// session, which `dragEnded` takes when AppKit lets go of it.
    @discardableResult
    public func startDragging(_ item: RearrangeDraft.Item) -> Int {
        dragSession += 1
        guard isRearranging else { return dragSession }
        draggedItem = item
        dropTarget = nil
        if case .entry(.project(let id)) = item { draggingProject = id } else { draggingProject = nil }
        return dragSession
    }

    /// The drag `session` is over, dropped or abandoned (Esc, let go outside the sidebar): its
    /// project unfolds and nothing is left dragged. A later drag's state is left alone.
    public func dragEnded(_ session: Int) {
        guard session == dragSession else { return }
        endDrag()
    }

    /// The drag is over `item`'s upper or lower half: the line is drawn there when the draft would
    /// take the drop, and none when it would refuse it. True when it would take it. With no drag of
    /// this sidebar's under way (a text drag from elsewhere), nothing is drawn.
    @discardableResult
    public func hover(over item: RearrangeDraft.Item, lowerHalf: Bool) -> Bool {
        guard let dragged = draggedItem, landing(of: dragged, on: item, lowerHalf: lowerHalf) != nil else {
            if dropTarget != nil { dropTarget = nil }
            return false
        }
        // Drawn where the drop lands: an unfolded project takes its lower half as before itself.
        let landsBefore = RearrangeDrop.target(for: item, lowerHalf: lowerHalf, in: rows) == item
        let target = RearrangeDropTarget(item: item, lowerHalf: lowerHalf && !landsBefore)
        if dropTarget != target { dropTarget = target }
        return true
    }

    /// A drop on `item`'s upper or lower half carrying `payload`, the dragged row's id: moved in the
    /// draft when the payload is a row of this draft and the rules allow it. What was dragged is
    /// read from the payload alone, so a stale or foreign drag moves nothing. The drag is over either way.
    @discardableResult
    public func drop(payload: String, on item: RearrangeDraft.Item, lowerHalf: Bool) -> Bool {
        defer { endDrag() }
        guard let dragged = rows.first(where: { $0.id == payload }).flatMap(RearrangeDrop.item(of:)),
              let before = landing(of: dragged, on: item, lowerHalf: lowerHalf) else { return false }
        return moveInDraft(dragged, before: before)
    }

    /// Nothing is dragged and no line is drawn.
    public func endDrag() {
        draggedItem = nil
        if draggingProject != nil { draggingProject = nil }
        if dropTarget != nil { dropTarget = nil }
    }

    /// Where dropping `dragged` on `item` would put it (`.some(nil)` = the end of its list), or nil when refused.
    private func landing(of dragged: RearrangeDraft.Item, on item: RearrangeDraft.Item, lowerHalf: Bool) -> RearrangeDraft.Item?? {
        guard let draft = rearrange else { return nil }
        return RearrangeDrop.landing(of: dragged, on: item, lowerHalf: lowerHalf, in: rows, draft: draft)
    }
}
