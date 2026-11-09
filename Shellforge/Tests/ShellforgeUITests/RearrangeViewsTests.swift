import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Rearrange mode as it is drawn: where a drop lands, what the menus and VoiceOver offer, and the bar.
@MainActor @Suite struct RearrangeViewsTests {
    @MainActor private struct Setup {
        let model: SidebarModel, document: WorkspaceDocument
        let a: Project, b: Project, task: TaskItem, terminal: TerminalItem, other: TaskItem
    }

    /// Project A with SSH rows a1, a2 and children t1 (a task) and x (a terminal); project B with one task.
    private func setup() throws -> Setup {
        let folder = TestScratch.root.appendingPathComponent("shellforge-rearrange-views-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        var a = Project(name: "api", path: "/api")
        a.tunnels = [TunnelDefinition(alias: "a1"), TunnelDefinition(alias: "a2")]
        let b = Project(name: "web", path: "/web")
        let task = TaskItem(projectId: a.id, title: "t1", branch: "t1", worktreePath: "/api-worktrees/t1", baseBranch: "main")
        let terminal = TerminalItem(projectId: a.id, name: "x")
        let other = TaskItem(projectId: b.id, title: "w1", branch: "w1", worktreePath: "/web-worktrees/w1", baseBranch: "main")
        try document.update { w in
            w.projects += [a, b]; w.addTask(task); w.addTerminal(terminal); w.addTask(other)
        }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        return Setup(model: model, document: document, a: a, b: b, task: task, terminal: terminal, other: other)
    }

    @Test func dropTargets() throws {
        let s = try setup()
        s.model.beginRearrange()
        let rows = s.model.rows
        let a = s.a.id
        let x = RearrangeDraft.Item.child(project: a, .terminal(s.terminal.id))
        #expect(RearrangeDrop.target(for: .tunnel(project: a, alias: "a2"), lowerHalf: true, in: rows) == nil,
                "the end of A’s SSH rows")
        #expect(RearrangeDrop.target(for: .tunnel(project: a, alias: "a1"), lowerHalf: true, in: rows) == .tunnel(project: a, alias: "a2"))
        #expect(RearrangeDrop.target(for: x, lowerHalf: false, in: rows) == x)
        #expect(RearrangeDrop.target(for: .child(project: a, .task(s.task.id)), lowerHalf: true, in: rows) == x)
        #expect(RearrangeDrop.target(for: x, lowerHalf: true, in: rows) == nil, "the end of A’s tasks and terminals")
        #expect(RearrangeDrop.target(for: .entry(.project(a)), lowerHalf: true, in: rows) == .entry(.project(s.b.id)),
                "past A’s own rows, to the next project")
    }

    @Test func aDropOnlyLandsInItsOwnList() throws {
        let s = try setup()
        s.model.beginRearrange()
        let a = s.a.id
        let t1 = RearrangeDraft.Item.child(project: a, .task(s.task.id))
        let x = RearrangeDraft.Item.child(project: a, .terminal(s.terminal.id))
        s.model.startDragging(t1)
        #expect(!s.model.hover(over: .child(project: s.b.id, .task(s.other.id)), lowerHalf: true), "not onto another project")
        #expect(s.model.dropTarget == nil, "a refused drop draws no line")
        #expect(!s.model.hover(over: .tunnel(project: a, alias: "a2"), lowerHalf: true), "not among the SSH rows")
        #expect(s.model.hover(over: x, lowerHalf: true))
        #expect(s.model.dropTarget == RearrangeDropTarget(item: x, lowerHalf: true))
        #expect(s.model.drop(payload: "task-\(s.task.id)", on: x, lowerHalf: true))
        #expect(s.model.rearrange?.children[a] == [.terminal(s.terminal.id), .task(s.task.id)])
        #expect(s.model.dropTarget == nil && s.model.draggingProject == nil)
    }

    @Test func draggingAProjectFoldsItUntilTheDrop() throws {
        let s = try setup()
        s.model.beginRearrange()
        s.model.startDragging(.entry(.project(s.a.id)))
        #expect(s.model.draggingProject == s.a.id)
        s.model.endDrag()
        #expect(s.model.draggingProject == nil && s.model.dropTarget == nil)
    }

    /// Esc during a drag, or a let-go outside the sidebar: the session ends with no drop, and the
    /// project unfolds. A late end of an older session leaves the current drag alone.
    @Test func anAbandonedDragUnfoldsTheProject() throws {
        let s = try setup()
        s.model.beginRearrange()
        let first = s.model.startDragging(.entry(.project(s.a.id)))
        #expect(s.model.rows.count == 3, "A folds to its header while dragged: A, B, B’s task")
        s.model.dragEnded(first)
        #expect(s.model.draggingProject == nil && s.model.draggedItem == nil)
        #expect(s.model.rows.count == 7, "A’s SSH rows and children are back")
        let older = s.model.startDragging(.entry(.project(s.a.id)))
        _ = s.model.startDragging(.entry(.project(s.b.id)))
        s.model.dragEnded(older)
        #expect(s.model.draggingProject == s.b.id, "only its own session clears a drag")
    }

    /// What moves is read from the drop's payload: one that is no row of this draft — another app's
    /// text, or a row that is gone — moves nothing, even with a stale drag left over.
    @Test func aDropWhosePayloadIsNoDraftRowIsRefused() throws {
        let s = try setup()
        s.model.beginRearrange()
        let a = s.a.id
        let x = RearrangeDraft.Item.child(project: a, .terminal(s.terminal.id))
        s.model.startDragging(.child(project: a, .task(s.task.id)))
        let before = s.model.rearrange
        #expect(!s.model.drop(payload: "hello from another app", on: x, lowerHalf: true))
        #expect(!s.model.drop(payload: "task-\(UUID())", on: x, lowerHalf: true))
        #expect(s.model.rearrange == before)
        #expect(s.model.draggedItem == nil && s.model.dropTarget == nil)
        // Without any drag of its own, a hover draws nothing.
        #expect(!s.model.hover(over: x, lowerHalf: false) && s.model.dropTarget == nil)
    }

    @Test func leavingTheModeClearsTheDropTarget() throws {
        let s = try setup()
        s.model.beginRearrange()
        s.model.startDragging(.entry(.project(s.b.id)))
        #expect(s.model.hover(over: .entry(.project(s.a.id)), lowerHalf: false))
        s.model.cancelRearrange()
        #expect(s.model.dropTarget == nil)
        s.model.beginRearrange()
        s.model.startDragging(.entry(.project(s.b.id)))
        #expect(s.model.hover(over: .entry(.project(s.a.id)), lowerHalf: false))
        s.model.finishRearrange()
        #expect(s.model.dropTarget == nil)
    }

    @Test func menusOfferRearrangeNotMoves() {
        let lists = [
            ProjectHeaderRow.menuTitles(provider: .git, sshHost: nil, canOpenSSHHost: false, pullTitle: nil),
            DividerRow.menuTitles,
            TaskRowView.menuTitles(hasTabs: true, closeTitle: "Close Tab", kindName: "Task"),
            TerminalRowView.menuTitles,
            TunnelRowView.menuTitles,
        ]
        for titles in lists {
            #expect(titles.contains("Rearrange"), "\(titles)")
            #expect(!titles.contains("Move Up") && !titles.contains("Move Down"), "\(titles)")
        }
        #expect(TunnelRowView.menuTitles == ["Rearrange"])
    }

    @Test func voiceOverMovesOnlyInTheMode() throws {
        let divider = SidebarDivider(name: "Work", position: 0)
        let outside = DividerRow.voiceOverActions(DividerRowItem(divider: divider, canMoveUp: true, canMoveDown: true))
        #expect(!outside.contains("Move Up") && !outside.contains("Move Down"))
        let s = try setup()
        let a = s.a.id
        let added = TerminalItem(projectId: a, name: "y")
        try s.document.update { $0.addTerminal(added) }
        s.model.beginRearrange()
        let draft = try #require(s.model.rearrange)
        // A’s children are t1, x, y: x is in the middle.
        #expect(RearrangeRowActions.titles(for: .child(project: a, .terminal(s.terminal.id)), in: draft) == ["Move Up", "Move Down"])
        #expect(RearrangeRowActions.titles(for: .child(project: a, .task(s.task.id)), in: draft) == ["Move Down"])
        #expect(RearrangeRowActions.titles(for: .tunnel(project: a, alias: "a2"), in: draft) == ["Move Up"])
    }

    /// SwiftUI draws a button's title itself, out of AppKit's sight, so the words are the bar's own;
    /// the hosted bar is checked for key equivalents: none, so Return and Esc typed in the terminal
    /// that shares the window stay the shell's.
    @Test func theBarHasCancelAndDone() {
        #expect(RearrangeBar.title == "Rearranging")
        #expect(RearrangeBar.cancelTitle == "Cancel" && RearrangeBar.doneTitle == "Done")
        let host = NSHostingView(rootView: RearrangeBar(cancel: {}, done: {}, windowControls: nil).frame(width: 260))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        let keys = descendants(of: NSButton.self, in: host).map(\.keyEquivalent).filter { !$0.isEmpty }
        #expect(keys.isEmpty, "no key equivalents: \(keys)")
    }

    /// Esc is a responder action: it cancels from a view inside the sidebar, and a view beside it —
    /// the terminal — never reaches the sidebar with it.
    @Test func escCancelsOnlyFromInsideTheSidebar() throws {
        let s = try setup()
        let sidebar = SidebarHostingView(rootView: EmptyView())
        sidebar.cancelRearrange = { [model = s.model] in
            guard model.isRearranging else { return false }
            model.cancelRearrange()
            return true
        }
        let inside = Focusable(), terminal = Focusable()
        sidebar.addSubview(inside)
        let content = NSView()
        content.addSubview(sidebar)
        content.addSubview(terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        s.model.beginRearrange()
        #expect(window.makeFirstResponder(terminal))
        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        #expect(s.model.isRearranging, "Esc in the terminal is the terminal’s")
        #expect(window.makeFirstResponder(inside))
        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        #expect(!s.model.isRearranging, "Esc in the sidebar cancels")
    }

    /// Hiding the sidebar on purpose cancels the mode, through the one call the app makes for it.
    @Test func hidingTheSidebarCancels() throws {
        let s = try setup()
        let sidebar = SidebarHostingView(rootView: EmptyView())
        sidebar.cancelRearrange = { [model = s.model] in
            model.cancelRearrange()
            return true
        }
        s.model.beginRearrange()
        ShellforgeSidebar.willHide(NSView())
        #expect(s.model.isRearranging, "not a sidebar: nothing happens")
        ShellforgeSidebar.willHide(sidebar)
        #expect(!s.model.isRearranging)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { [$0 as? T].compactMap { $0 } + descendants(of: type, in: $0) }
    }
}

/// A view that takes the keyboard, standing for a sidebar row or the terminal.
private final class Focusable: NSView {
    override var acceptsFirstResponder: Bool { true }
}
