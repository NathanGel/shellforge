import AppKit
import Foundation
import ShellforgeDesign
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The activity bar's model: each window picks its own panel, every window shares one saved order,
/// and the Sessions panel's state and commands live on while another panel shows.
@MainActor @Suite struct ActivityBarTests {
    private func task(_ title: String, in project: UUID) -> TaskItem {
        TaskItem(projectId: project, title: title, branch: "feat/\(title)", worktreePath: "/wt/\(title)", baseBranch: "main")
    }

    /// Project `demo` with tasks `a1` and `a2`, and the sidebar model over it.
    private func sidebarModel() throws -> (SidebarModel, [String: UUID]) {
        let folder = TestScratch.root.appendingPathComponent("shellforge-activity-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        let project = Project(name: "demo", path: "/demo")
        try document.update { workspace in
            workspace.projects.append(project)
            workspace.tasks += [task("a1", in: project.id), task("a2", in: project.id)]
        }
        var ids = ["demo": project.id]
        for task in document.workspace.tasks { ids[task.title] = task.id }
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return (SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil }), ids)
    }

    @Test func selectionIsPerWindow() {
        let source = ActivityOrderSource(defaults: ScratchDefaults.make())
        let first = ActivityModel(source: source), second = ActivityModel(source: source)
        first.select(.metrics)
        #expect(first.layout.selected == .metrics)
        #expect(second.layout.selected == .sessions)
    }

    @Test func orderIsSharedAndSaved() {
        let defaults = ScratchDefaults.make()
        let source = ActivityOrderSource(defaults: defaults)
        let first = ActivityModel(source: source), second = ActivityModel(source: source)
        first.move(.metrics, before: .sessions)
        #expect(first.layout.order == [.metrics, .sessions])
        #expect(second.layout.order == [.metrics, .sessions])
        #expect(ActivityOrderStore.load(defaults) == ["metrics", "sessions"])
        #expect(ActivityModel(defaults: defaults).layout.order == [.metrics, .sessions], "a new window reads the saved order")
    }

    @Test func movingKeepsTheSelection() {
        let model = ActivityModel(source: ActivityOrderSource(defaults: ScratchDefaults.make()))
        model.select(.metrics)
        model.move(.metrics, before: .sessions)
        #expect(model.layout.selected == .metrics)
    }

    /// The bar's List hands back offsets; dropping a panel where it already is changes nothing.
    @Test func listOffsetsMoveThePanel() {
        let defaults = ScratchDefaults.make()
        let model = ActivityModel(defaults: defaults)
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 0)
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 1)
        #expect(model.layout.order == [.sessions, .metrics])
        #expect(ActivityOrderStore.load(defaults) == nil, "nothing moved, so nothing is saved")
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(model.layout.order == [.metrics, .sessions])
        model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(model.layout.order == [.sessions, .metrics])
    }

    /// The whole sidebar, hosted in a window, with this window's activity bar `activity`.
    private func hosted(_ sidebar: SidebarModel, activity: ActivityModel, controls: SidebarWindowControls?) -> (NSHostingView<AnyView>, NSWindow) {
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("activity-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let chrome = SidebarChrome()
        chrome.windowControls = controls
        let view = SidebarView(model: sidebar, activity: activity, chooseFolder: { nil }, hooks: hooks,
                               machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                               backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                               terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()),
                               feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev), chrome: chrome,
                               showBackpack: { _ in }, showFeedback: { _ in }, hideSidebar: {}, agentTools: .none, agentsChanged: {})
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    /// Whether `view` is drawn: no view between it and `host` is hidden or fully transparent.
    private func isShown(_ view: NSView, in host: NSView) -> Bool {
        !sequence(first: view, next: \.superview).prefix { $0 !== host }.contains { $0.isHidden || $0.alphaValue == 0 }
    }

    /// The hosted Rearrange bars that are drawn.
    private func shownRearrangeBars(in host: NSView) -> [NSView] {
        host.layoutSubtreeIfNeeded()
        return descendants(of: host).filter { $0.identifier?.rawValue == RearrangeBar.markName && isShown($0, in: host) }
    }

    /// The Sessions list: the table that is not the activity bar's, the one with the most rows.
    private func sessionsTable(in host: NSView) throws -> NSTableView {
        host.layoutSubtreeIfNeeded()
        return try #require(descendants(of: host).compactMap { $0 as? NSTableView }.max { $0.numberOfRows < $1.numberOfRows })
    }

    /// Rearrange mode is not left behind a panel: with Metrics showing, its bar (Cancel and Done,
    /// `RearrangeViewsTests.theBarHasCancelAndDone`) is still drawn, the mode and its draft hold, and
    /// back on Sessions the draft is as it was.
    @Test(arguments: [nil, SidebarWindowControls(buttonsMaxX: 70, buttonsMidY: 20)])
    func theRearrangeBarShowsWhateverPanelIsSelected(controls: SidebarWindowControls?) throws {
        let (sidebar, ids) = try sidebarModel()
        let project = try #require(ids["demo"]), a1 = try #require(ids["a1"]), a2 = try #require(ids["a2"])
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let (host, window) = hosted(sidebar, activity: activity, controls: controls)
        defer { window.close() }
        #expect(shownRearrangeBars(in: host).isEmpty, "a Rearrange bar outside the mode")
        sidebar.beginRearrange()
        #expect(sidebar.moveInDraft(.child(project: project, .task(a2)), before: .child(project: project, .task(a1))))
        let draft = sidebar.rearrange
        #expect(shownRearrangeBars(in: host).count == 1, "no Rearrange bar on Sessions")
        activity.select(.metrics)
        #expect(shownRearrangeBars(in: host).count == 1, "no Rearrange bar on Metrics")
        #expect(sidebar.isRearranging)
        activity.select(.sessions)
        #expect(shownRearrangeBars(in: host).count == 1)
        #expect(sidebar.rearrange == draft, "the draft changed on the way back to Sessions")
    }

    /// The Sessions panel stays mounted behind another panel, so its scroll position, rows and focus
    /// survive: the same list, hidden while Metrics shows and drawn again after.
    @Test func sessionsStaysMountedButHiddenBehindMetrics() throws {
        let (sidebar, _) = try sidebarModel()
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let (host, window) = hosted(sidebar, activity: activity, controls: nil)
        defer { window.close() }
        let list = try sessionsTable(in: host)
        #expect(isShown(list, in: host))
        activity.select(.metrics)
        #expect(try sessionsTable(in: host) === list, "Sessions’ list was torn down")
        #expect(!isShown(list, in: host), "Sessions’ list still shows behind Metrics")
        activity.select(.sessions)
        #expect(try sessionsTable(in: host) === list)
        #expect(isShown(list, in: host))
    }

    /// The Sessions panel's content is as wide as the sidebar was before the bar: the bar's width was
    /// added to the sidebar's.
    @Test func theBarAddsToTheSidebarRatherThanTakingFromIt() {
        for scale in InterfaceScale.all {
            #expect(scale(Size.sidebarMinWidth) - ActivityBar.width(scale) >= scale(360), "at ×\(scale.factor)")
            #expect(scale(Size.sidebarWidth) - ActivityBar.width(scale) >= scale(420), "at ×\(scale.factor)")
        }
    }
}
