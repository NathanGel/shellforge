import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Rearrange mode as it is drawn: where a move lands, what the menus and VoiceOver offer, and the bar.
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

    /// The setup with a second task t2 in A and a divider D between A and B, in the mode, A's
    /// children ordered t1, t2, x. Rows: A 0, a1 1, a2 2, t1 3, t2 4, x 5, D 6, B 7, w1 8.
    @MainActor private struct Arranged {
        let s: Setup, t2: TaskItem, divider: SidebarDivider
        var model: SidebarModel { s.model }
        var a: UUID { s.a.id }
        var t1: RearrangeDraft.Item { .child(project: s.a.id, .task(s.task.id)) }
        var t2Item: RearrangeDraft.Item { .child(project: s.a.id, .task(t2.id)) }
        var x: RearrangeDraft.Item { .child(project: s.a.id, .terminal(s.terminal.id)) }
        func ids() -> [String] { model.rows.map(\.id) }
    }

    private func arranged() throws -> Arranged {
        let s = try setup()
        let t2 = TaskItem(projectId: s.a.id, title: "t2", branch: "t2", worktreePath: "/api-worktrees/t2", baseBranch: "main")
        let divider = SidebarDivider(name: "Work", position: 1)
        try s.document.update { w in w.addTask(t2); w.dividers = [divider] }
        s.model.beginRearrange()
        #expect(s.model.moveInDraft(.child(project: s.a.id, .terminal(s.terminal.id)), before: nil))
        let r = Arranged(s: s, t2: t2, divider: divider)
        #expect(r.ids() == ["project-\(s.a.id)", "tunnel-\(s.a.id)-a1", "tunnel-\(s.a.id)-a2", "task-\(s.task.id)", "task-\(t2.id)",
                            "terminal-\(s.terminal.id)", "divider-\(divider.id)", "project-\(s.b.id)", "task-\(s.other.id)"])
        return r
    }

    @Test func aProjectMovedAboveAnotherTakesItsRows() throws {
        let r = try arranged()
        let b = r.s.b.id
        let landing = try #require(RearrangeDrop.landing(moving: 7, to: 0, in: r.model.rows))
        #expect(landing.item == .entry(.project(b)) && landing.before == .entry(.project(r.a)))
        #expect(r.model.moveRows(from: [7], to: 0))
        #expect(Array(r.ids().prefix(3)) == ["project-\(b)", "task-\(r.s.other.id)", "project-\(r.a)"], "B’s task comes along under it")
        #expect(r.ids().last == "divider-\(r.divider.id)")
    }

    /// Projects cannot go inside projects: a drop among A’s rows lands after A.
    @Test func aProjectDroppedAmongAnotherProjectsRowsLandsAfterIt() throws {
        let r = try arranged()
        let b = r.s.b.id
        let landing = try #require(RearrangeDrop.landing(moving: 7, to: 4, in: r.model.rows))
        #expect(landing.before == .entry(.divider(r.divider.id)))
        #expect(r.model.moveRows(from: [7], to: 4))
        #expect(r.model.rearrange?.entries == [.project(r.a), .project(b), .divider(r.divider.id)])
        #expect(r.ids()[6] == "project-\(b)" && r.ids()[5] == "terminal-\(r.s.terminal.id)", "A keeps all its rows")
    }

    @Test func aDividerMovesAlone() throws {
        let r = try arranged()
        #expect(r.model.moveRows(from: [6], to: 0))
        #expect(r.model.rearrange?.entries == [.divider(r.divider.id), .project(r.a), .project(r.s.b.id)])
        #expect(r.ids().count == 9)
        #expect(r.model.moveRows(from: [0], to: 9), "to the end")
        #expect(r.model.rearrange?.entries == [.project(r.a), .project(r.s.b.id), .divider(r.divider.id)])
    }

    @Test func aTerminalMovesBetweenTwoTasks() throws {
        let r = try arranged()
        let landing = try #require(RearrangeDrop.landing(moving: 5, to: 4, in: r.model.rows))
        #expect(landing.item == r.x && landing.before == r.t2Item)
        #expect(r.model.moveRows(from: [5], to: 4))
        #expect(r.model.rearrange?.children[r.a] == [.task(r.s.task.id), .terminal(r.s.terminal.id), .task(r.t2.id)])
    }

    /// One past A’s last child is the end of A’s list, though it is also the divider’s place.
    @Test func aTaskMovedOnePastItsProjectsChildrenLandsAtTheEnd() throws {
        let r = try arranged()
        let landing = try #require(RearrangeDrop.landing(moving: 3, to: 6, in: r.model.rows))
        #expect(landing.item == r.t1 && landing.before == nil)
        #expect(r.model.moveRows(from: [3], to: 6))
        #expect(r.model.rearrange?.children[r.a] == [.task(r.t2.id), .terminal(r.s.terminal.id), .task(r.s.task.id)])
    }

    @Test func aTaskMovedIntoAnotherProjectIsRefused() throws {
        let r = try arranged()
        let before = r.model.rearrange
        for destination in [7, 8, 9] {
            #expect(RearrangeDrop.landing(moving: 3, to: destination, in: r.model.rows) == nil, "\(destination)")
            #expect(!r.model.moveRows(from: [3], to: destination), "\(destination)")
        }
        #expect(r.model.rearrange == before)
    }

    @Test func aTaskMovedAmongOrAboveTheSSHRowsIsRefused() throws {
        let r = try arranged()
        let before = r.model.rearrange
        for destination in [0, 1, 2] {
            #expect(RearrangeDrop.landing(moving: 4, to: destination, in: r.model.rows) == nil, "\(destination)")
            #expect(!r.model.moveRows(from: [4], to: destination), "\(destination)")
        }
        #expect(r.model.rearrange == before)
    }

    @Test func anSSHRowMovesAmongItsOwnOnly() throws {
        let r = try arranged()
        #expect(r.model.moveRows(from: [2], to: 1))
        #expect(r.model.rearrange?.tunnels[r.a] == ["a2", "a1"])
        #expect(r.model.moveRows(from: [1], to: 3), "one past the SSH rows: their end")
        #expect(r.model.rearrange?.tunnels[r.a] == ["a1", "a2"])
        let before = r.model.rearrange
        for destination in [0, 4, 5, 6] {
            #expect(!r.model.moveRows(from: [1], to: destination), "\(destination)")
        }
        #expect(r.model.rearrange == before)
    }

    /// Rows that stand for nothing in the draft do not move.
    @Test func rowsThatDoNotMoveAreRefused() {
        let tab = SidebarRow.tab(TabSnapshot(id: "t1", tabId: 1, title: "zsh", taskId: nil, projectId: nil), selected: false)
        let rows: [SidebarRow] = [.empty, .otherTabsHeading, tab]
        for source in rows.indices {
            for destination in 0...rows.count {
                #expect(RearrangeDrop.landing(moving: source, to: destination, in: rows) == nil, "\(source) to \(destination)")
            }
        }
        #expect(RearrangeDrop.landing(moving: 5, to: 0, in: rows) == nil, "no such row")
    }

    @Test func outsideTheModeMoveRowsDoesNothing() throws {
        let s = try setup()
        let before = s.document.workspace
        let rows = s.model.rows.map(\.id)
        #expect(!s.model.moveRows(from: [5], to: 0))
        #expect(s.document.workspace == before && s.model.rows.map(\.id) == rows && !s.model.isRearranging)
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
        let outside = DividerRow.voiceOverActions()
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

    /// Outside the mode, Esc in the sidebar is not the sidebar's: it goes on up the responder chain,
    /// unchanged, and nothing raises (NSView has no `cancelOperation:` to call up to).
    @Test func escOutsideTheModePassesOn() throws {
        let s = try setup()
        let sidebar = SidebarHostingView(rootView: EmptyView())
        sidebar.cancelRearrange = { [model = s.model] in
            guard model.isRearranging else { return false }
            model.cancelRearrange()
            return true
        }
        let inside = Focusable()
        sidebar.addSubview(inside)
        let content = EscRecorder()
        content.addSubview(sidebar)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        #expect(window.makeFirstResponder(inside))
        #expect(window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil) == true)
        #expect(content.escapes == 1, "it reached the responder after the sidebar")
        #expect(!s.model.isRearranging)
        s.model.beginRearrange()
        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        #expect(!s.model.isRearranging && content.escapes == 1, "in the mode the sidebar takes it")
        // With no one further up to take it, it is simply dropped.
        let alone = SidebarHostingView(rootView: EmptyView())
        alone.cancelOperation(nil)
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

    /// The fold still works in the mode, and VoiceOver can do it too.
    @Test func aProjectStillFoldsInTheMode() throws {
        let s = try setup()
        s.model.beginRearrange()
        #expect(s.model.rows.count == 7)
        s.model.toggleCollapsed(s.a.id)
        #expect(s.model.isRearranging)
        #expect(s.model.rows.map(\.id).first == "project-\(s.a.id)" && s.model.rows.count == 3, "A folded to its header")
        #expect(RearrangeRowActions.foldTitle(collapsed: false) == "Fold")
        #expect(RearrangeRowActions.foldTitle(collapsed: true) == "Unfold")
    }

    /// Every arrangeable row offers Rearrange to VoiceOver alike: outside the mode, while no other window has it.
    @Test func voiceOverOffersRearrangeAlike() {
        #expect(RearrangeMenuItem.offeredToVoiceOver(canRearrange: true, isRearranging: false))
        #expect(!RearrangeMenuItem.offeredToVoiceOver(canRearrange: false, isRearranging: false))
        #expect(!RearrangeMenuItem.offeredToVoiceOver(canRearrange: true, isRearranging: true))
    }

    /// Begun from a context menu, the mode takes the keyboard from the terminal so Esc works at once,
    /// and gives it back on Done or Cancel; Esc typed to the sidebar itself cancels.
    @Test func theModeTakesTheKeyboardAndGivesItBack() throws {
        let s = try setup()
        let sidebar = SidebarHostingView(rootView: EmptyView())
        sidebar.cancelRearrange = { [model = s.model] in
            guard model.isRearranging else { return false }
            model.cancelRearrange()
            return true
        }
        sidebar.watchRearrange(s.model.$rearrange.map { $0 != nil })
        let terminal = Focusable()
        let content = NSView()
        content.addSubview(sidebar)
        content.addSubview(terminal)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.close() }
        #expect(window.makeFirstResponder(terminal))
        s.model.beginRearrange()
        #expect(window.firstResponder === sidebar)
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        sidebar.keyDown(with: esc)
        #expect(!s.model.isRearranging, "Esc cancels at once")
        #expect(window.firstResponder === terminal, "the terminal has the keyboard back")
        // Moved to the terminal meanwhile: Done leaves it there.
        s.model.beginRearrange()
        #expect(window.makeFirstResponder(terminal))
        s.model.finishRearrange()
        #expect(window.firstResponder === terminal)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { [$0 as? T].compactMap { $0 } + descendants(of: type, in: $0) }
    }
}

/// A responder that counts the Esc presses that reach it.
private final class EscRecorder: NSView {
    var escapes = 0
    @objc override func cancelOperation(_ sender: Any?) { escapes += 1 }
}

/// A view that takes the keyboard, standing for a sidebar row or the terminal.
private final class Focusable: NSView {
    override var acceptsFirstResponder: Bool { true }
}
