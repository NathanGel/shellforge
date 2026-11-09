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
        draggingProject = nil
        if document.rearranger === self { document.rearranger = nil }
    }
}
