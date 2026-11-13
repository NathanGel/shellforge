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
        #expect(first.layout.order == [.metrics, .sessions, .files, .git, .ssh])
        #expect(second.layout.order == [.metrics, .sessions, .files, .git, .ssh])
        #expect(ActivityOrderStore.load(defaults) == ["metrics", "sessions", "files", "git", "ssh"])
        #expect(ActivityModel(defaults: defaults).layout.order == [.metrics, .sessions, .files, .git, .ssh], "a new window reads the saved order")
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
        #expect(model.layout.order == [.sessions, .metrics, .files, .git, .ssh])
        #expect(ActivityOrderStore.load(defaults) == nil, "nothing moved, so nothing is saved")
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(model.layout.order == [.metrics, .sessions, .files, .git, .ssh])
        model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(model.layout.order == [.sessions, .metrics, .files, .git, .ssh])
    }

    /// A drag's drop, as `move(fromOffsets:toOffset:)` takes it: past half a cell the icon trades
    /// places with its neighbour, beyond either end it stops there, and a click's small slip of the
    /// mouse moves nothing.
    @Test func aDragDropsWhereItIsReleased() {
        let cell: CGFloat = 44
        func drop(_ from: Int, _ translation: CGFloat) -> Int? {
            ActivityBar.dropOffset(from: from, translation: translation, cell: cell, count: 3)
        }
        #expect(drop(0, cell) == 2, "down one cell")
        #expect(drop(2, -cell) == 1, "up one cell")
        #expect(drop(1, 0.6 * cell) == 3 && drop(1, -0.6 * cell) == 0, "past half a cell")
        #expect(drop(0, 10 * cell) == 3, "beyond the end")
        #expect(drop(2, -10 * cell) == 0, "beyond the start")
        #expect(drop(1, 2) == nil && drop(1, -2) == nil, "a click’s slip")
        #expect(drop(1, 0.4 * cell) == nil, "short of half a cell")
        #expect(drop(0, -cell) == nil && drop(2, cell) == nil, "already at that end")
        #expect(!ActivityBar.lifts(2) && ActivityBar.lifts(ActivityBar.liftDistance), "a click does not lift the icon")
    }

    /// A release: short of a lift it is a click and selects; lifted, it moves the icon, or nothing
    /// when it lands where it was.
    @Test func aReleaseSelectsOrMoves() {
        let cell: CGFloat = 44
        #expect(ActivityBar.release(from: 1, translation: 1, cell: cell, count: 3) == .select)
        #expect(ActivityBar.release(from: 0, translation: cell, cell: cell, count: 3) == .move(toOffset: 2))
        #expect(ActivityBar.release(from: 1, translation: 0.3 * cell, cell: cell, count: 3) == .stay)
    }

    /// VoiceOver's Move Up and Move Down, as `move(fromOffsets:toOffset:)` takes them, and only where
    /// the icon can go that way.
    @Test func voiceOverStepsAnIconOneCell() {
        #expect(ActivityBar.stepOffset(from: 1, up: true, count: 3) == 0)
        #expect(ActivityBar.stepOffset(from: 1, up: false, count: 3) == 3)
        #expect(ActivityBar.stepOffset(from: 0, up: true, count: 3) == nil)
        #expect(ActivityBar.stepOffset(from: 2, up: false, count: 3) == nil)
        #expect(ActivityBar.voiceOverActions(at: 0, count: 3) == [ActivityBar.moveDown])
        #expect(ActivityBar.voiceOverActions(at: 1, count: 3) == [ActivityBar.moveUp, ActivityBar.moveDown])
        #expect(ActivityBar.voiceOverActions(at: 2, count: 3) == [ActivityBar.moveUp])
        #expect(ActivityBar.voiceOverActions(at: 0, count: 1).isEmpty)
        #expect([ActivityBar.moveUp, ActivityBar.moveDown] == ["Move Up", "Move Down"])
    }

    /// Move Up and Move Down, handed to the model, step the panel one place.
    @Test func voiceOverStepsMoveThePanel() throws {
        let model = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let count = model.layout.order.count
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: try #require(ActivityBar.stepOffset(from: 0, up: false, count: count)))
        #expect(model.layout.order == [.metrics, .sessions, .files, .git, .ssh])
        model.move(fromOffsets: IndexSet(integer: 1), toOffset: try #require(ActivityBar.stepOffset(from: 1, up: true, count: count)))
        #expect(model.layout.order == [.sessions, .metrics, .files, .git, .ssh])
    }

    /// The drop, handed to the model: the dragged panel lands where it was released.
    @Test func aDropMovesThePanel() throws {
        let model = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let cell = ActivityBar.width(.standard)
        let destination = try #require(ActivityBar.dropOffset(from: 0, translation: cell, cell: cell, count: model.layout.order.count))
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: destination)
        #expect(model.layout.order == [.metrics, .sessions, .files, .git, .ssh])
    }

    /// The whole sidebar, hosted in a window, with this window's activity bar `activity`.
    private func hosted(_ sidebar: SidebarModel, activity: ActivityModel, controls: SidebarWindowControls?,
                        files: FilesHolder? = nil) -> (NSHostingView<AnyView>, NSWindow) {
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("activity-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let chrome = SidebarChrome()
        chrome.windowControls = controls
        let view = SidebarView(model: sidebar, activity: activity, chooseFolder: { nil }, hooks: hooks,
                               machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                               backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                               terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()), theme: ThemeSettings(defaults: ScratchDefaults.make()), appDefaults: ScratchDefaults.make(),
                               files: files, feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev), chrome: chrome,
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

    /// The app has one Files model: nothing is listed or watched until the panel first shows in
    /// some window, and another window's panel draws the same model.
    @Test func windowsShareOneFilesModelMadeWhenFirstShown() throws {
        final class Count { var made = 0 }
        let count = Count()
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let holder = FilesHolder {
            count.made += 1
            return FilesModel(projects: [], launcher: launcher, defaults: ScratchDefaults.make(), watcher: { _ in FolderWatcher() })
        }
        let (firstSidebar, _) = try sidebarModel()
        let (secondSidebar, _) = try sidebarModel()
        let first = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let second = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let (firstHost, firstWindow) = hosted(firstSidebar, activity: first, controls: nil, files: holder)
        let (secondHost, secondWindow) = hosted(secondSidebar, activity: second, controls: nil, files: holder)
        defer { firstWindow.close(); secondWindow.close() }
        let drawsFiles = { (host: NSView) -> Bool in
            host.layoutSubtreeIfNeeded()
            return self.descendants(of: host).contains { $0.identifier?.rawValue == FilesPanel.markName }
        }
        #expect(!drawsFiles(firstHost) && !drawsFiles(secondHost))
        #expect(count.made == 0 && holder.made == nil, "made before the panel showed")
        first.select(.files)
        #expect(drawsFiles(firstHost))
        #expect(count.made == 1)
        second.select(.files)
        #expect(drawsFiles(secondHost))
        #expect(count.made == 1, "a second window made a model of its own")
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

    /// The sidebar as the app makes it, in a window, and the activity bar it made.
    private func made(_ sidebar: SidebarModel) throws -> (NSView, NSWindow, ActivityModel) {
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("activity-made-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let view = ShellforgeSidebar.makeView(model: sidebar, chooseFolder: { nil }, hooks: hooks,
                                              machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                              backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                              zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()), theme: ThemeSettings(defaults: ScratchDefaults.make()), appDefaults: ScratchDefaults.make(),
                                              feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev))
        view.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let activity = try #require((view as? SidebarHostingView<ZoomedSidebar>)?.activity)
        return (view, window, activity)
    }

    /// Behind Metrics the Sessions list is out of the keyboard's reach too: it cannot take the
    /// keyboard, so Tab, the arrows, Return and type-select never land on a list nobody sees.
    @Test(arguments: [nil, SidebarWindowControls(buttonsMaxX: 70, buttonsMidY: 20)])
    func theHiddenSessionsListCannotTakeTheKeyboard(controls: SidebarWindowControls?) throws {
        let (sidebar, _) = try sidebarModel()
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let (host, window) = hosted(sidebar, activity: activity, controls: controls)
        defer { window.close() }
        let list = try sessionsTable(in: host)
        _ = window.makeFirstResponder(list)
        #expect(window.firstResponder === list, "on Sessions the list takes the keyboard")
        _ = window.makeFirstResponder(nil)
        activity.select(.metrics)
        host.layoutSubtreeIfNeeded()
        #expect(!list.acceptsFirstResponder && !list.isEnabled)
        // AppKit answers true even for a view that refuses: where the keyboard went is what counts.
        _ = window.makeFirstResponder(list)
        #expect(window.firstResponder !== list, "the hidden list took the keyboard")
        activity.select(.sessions)
        host.layoutSubtreeIfNeeded()
        _ = window.makeFirstResponder(list)
        #expect(window.firstResponder === list, "back on Sessions it takes it again")
    }

    /// The keyboard in the Sessions list when Metrics is picked: it moves to the sidebar itself, so
    /// it is never left on the hidden list — and Esc still reaches Rearrange mode there.
    @Test func theKeyboardLeavesSessionsWhenAnotherPanelShows() throws {
        let (sidebar, _) = try sidebarModel()
        let (view, window, activity) = try made(sidebar)
        defer { window.close() }
        let list = try sessionsTable(in: view)
        _ = window.makeFirstResponder(list)
        #expect(window.firstResponder === list)
        activity.select(.metrics)
        #expect(window.firstResponder === view, "the keyboard is on \(String(describing: window.firstResponder))")
        sidebar.beginRearrange()
        _ = window.firstResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil)
        #expect(!sidebar.isRearranging, "Esc in the sidebar cancels")
    }

    /// Back on Sessions, the keyboard the host took for the switch goes back to the list it came from.
    @Test func theKeyboardReturnsToTheListWithSessions() throws {
        let (sidebar, _) = try sidebarModel()
        let (view, window, activity) = try made(sidebar)
        defer { window.close() }
        let list = try sessionsTable(in: view)
        _ = window.makeFirstResponder(list)
        activity.select(.metrics)
        view.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === view)
        activity.select(.sessions)
        view.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === list, "the keyboard stayed on \(String(describing: window.firstResponder))")
    }

    /// The keyboard left the sidebar while Metrics showed: coming back to Sessions does not take it back.
    @Test func theKeyboardIsNotTakenBackFromElsewhere() throws {
        let (sidebar, _) = try sidebarModel()
        let (view, window, activity) = try made(sidebar)
        defer { window.close() }
        let list = try sessionsTable(in: view)
        _ = window.makeFirstResponder(list)
        activity.select(.metrics)
        view.layoutSubtreeIfNeeded()
        _ = window.makeFirstResponder(nil)
        activity.select(.sessions)
        view.layoutSubtreeIfNeeded()
        #expect(window.firstResponder !== list)
    }

    /// View › Show Sessions, Metrics, Files, Git and SSH: each item names its panel, its key is a free ⌃⌘ one,
    /// and showing it on a sidebar selects that panel.
    @Test func theViewMenusPanelCommandsSelectThePanel() throws {
        let (sidebar, _) = try sidebarModel()
        let (view, window, activity) = try made(sidebar)
        defer { window.close() }
        let items = SidebarCommandMenu.panels
        #expect(items.map(\.panel) == ActivityPanel.allCases)
        #expect(items.map(\.title) == ["Show Sessions", "Show Metrics", "Show Files", "Show Git", "Show SSH"])
        for item in items.reversed() {
            ShellforgeSidebar.show(item.panel, on: view)
            #expect(activity.layout.selected == item.panel)
            #expect(ShellforgeSidebar.shownPanel(of: view) == item.panel)
        }
        let taken = (SidebarCommandMenu.items.filter { $0.command != nil } + [SidebarCommandMenu.toggleSidebar]).map(\.key)
        // Show Git has no key: every ⌃⌘ letter of its name is taken.
        let keyed = items.filter { !$0.key.isEmpty }
        let keys = keyed.map(\.key)
        #expect(Set(keys).count == keys.count && Set(keys).isDisjoint(with: taken), "a key used twice")
        #expect(Set(keys).isDisjoint(with: SidebarCommandMenu.systemReserved.union(["f"])), "macOS’s or iTerm2’s")
        #expect(keyed.allSatisfy { $0.modifiers == [.control, .command] })
        #expect(items.filter { $0.key.isEmpty }.map(\.panel) == [.git])
    }

    /// An error raised while Metrics shows — a ⌃⌘ command that failed, say — is seen there: the
    /// banners are pinned above every panel, not inside Sessions.
    @Test(arguments: [nil, SidebarWindowControls(buttonsMaxX: 70, buttonsMidY: 20)])
    func bannersShowWhateverPanelIsSelected(controls: SidebarWindowControls?) throws {
        let (sidebar, _) = try sidebarModel()
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let (host, window) = hosted(sidebar, activity: activity, controls: controls)
        defer { window.close() }
        activity.select(.metrics)
        #expect(shown(SidebarBanner.markName, in: host).isEmpty)
        sidebar.lastError = "The worktree for demo couldn’t be created."
        #expect(shown(SidebarBanner.markName, in: host).count == 1, "the error is out of sight on Metrics")
        activity.select(.sessions)
        #expect(shown(SidebarBanner.markName, in: host).count == 1, "the error is out of sight on Sessions")
    }

    /// `view`'s frame in `host`, measured from its top-left corner.
    private func frame(of view: NSView, in host: NSView) -> CGRect {
        let frame = view.convert(view.bounds, to: host)
        return host.isFlipped ? frame : CGRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
    }

    /// The one drawn mark named `name`'s frame in `host`.
    private func shownFrame(_ name: String, in host: NSView) throws -> CGRect {
        let marks = shown(name, in: host)
        #expect(marks.count == 1, "\(marks.count) \(name) drawn")
        return frame(of: try #require(marks.first), in: host)
    }

    /// VS Code's bar: each icon, the gear too, centred in the bar; the selected one's accent stripe
    /// flush with its left edge and a cell high; the bar from the top of the sidebar, or from below
    /// the window buttons' band; and the panel's header in the column beside it, not across it.
    @Test(arguments: [nil, SidebarWindowControls(buttonsMaxX: 70, buttonsMidY: 20),
                      SidebarWindowControls(buttonsMaxX: 40, buttonsMidY: 20, stacked: true)])
    func theBarIsCentredAndRunsBesideThePanel(controls: SidebarWindowControls?) throws {
        let (sidebar, _) = try sidebarModel()
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let (host, window) = hosted(sidebar, activity: activity, controls: controls)
        defer { window.close() }
        for panel in ActivityPanel.allCases {
            activity.select(panel)
            let bar = try shownFrame(ActivityBar.markName, in: host)
            #expect(abs(bar.width - ActivityBar.width(.standard)) < 0.5)
            #expect(abs(bar.minY - (controls?.bandHeight ?? 0)) < 0.5, "the bar starts at \(bar.minY)")
            let cell = ActivityBar.width(.standard)
            let icons = shown(ActivityBar.iconMarkName, in: host).map { frame(of: $0, in: host) }.sorted { $0.midY < $1.midY }
            #expect(icons.count == ActivityPanel.allCases.count + 1, "a panel icon each, and the gear")
            for icon in icons { #expect(abs(icon.midX - bar.midX) <= 0.5, "an icon off-centre: \(icon) in \(bar)") }
            // Down the bar too: each panel's glyph in the middle of its cell, the gear in the last.
            for (index, icon) in icons.dropLast().enumerated() {
                #expect(abs(icon.midY - (bar.minY + (CGFloat(index) + 0.5) * cell)) <= 0.5, "icon \(index) off its cell's middle: \(icon)")
            }
            let gear = try #require(icons.last)
            #expect(abs(gear.midY - (bar.maxY - cell / 2)) <= 0.5, "the gear off its cell's middle: \(gear) in \(bar)")
            let stripe = try shownFrame(ActivityBar.stripeMarkName, in: host)
            #expect(abs(stripe.minX - bar.minX) < 0.5, "the stripe is detached from the bar's edge")
            #expect(abs(stripe.height - ActivityBar.width(.standard)) < 0.5, "the stripe is a cell high")
            let index = try #require(activity.layout.order.firstIndex(of: panel))
            #expect(abs(stripe.minY - (bar.minY + CGFloat(index) * ActivityBar.width(.standard))) < 0.5, "the stripe is beside its icon")
            let header = try shownFrame(SidebarHeader.markName, in: host)
            #expect(header.minX >= bar.maxX, "the header reaches across the bar: \(header)")
            #expect(header.minY >= bar.minY, "the header is above the bar's top")
        }
        sidebar.beginRearrange()
        let bar = try shownFrame(ActivityBar.markName, in: host)
        #expect(try shownFrame(RearrangeBar.markName, in: host).minX >= bar.maxX, "the Rearrange bar reaches across the bar")
    }

    /// The marks named `name` that are drawn.
    private func shown(_ name: String, in host: NSView) -> [NSView] {
        host.layoutSubtreeIfNeeded()
        return descendants(of: host).filter { $0.identifier?.rawValue == name && isShown($0, in: host) }
    }

    /// The Tasks menu's commands go through the model, so they work while Metrics shows.
    @Test func commandsWorkWhileAnotherPanelShows() throws {
        let (sidebar, ids) = try sidebarModel()
        let (view, window, activity) = try made(sidebar)
        defer { window.close() }
        activity.select(.metrics)
        view.layoutSubtreeIfNeeded()
        #expect(sidebar.can(.newTask), "the only project is New Task’s target")
        sidebar.perform(.nextTask)
        #expect(sidebar.selectedTaskId == ids["a1"])
        sidebar.perform(.nextTask)
        #expect(sidebar.selectedTaskId == ids["a2"])
    }

    /// The Sessions panel's content is as wide as the sidebar was before the bar: the bar's width was
    /// added to the sidebar's.
    @Test func theBarAddsToTheSidebarRatherThanTakingFromIt() {
        for scale in InterfaceScale.all {
            #expect(scale(Size.sidebarMinWidth) - ActivityBar.width(scale) >= scale(360), "at ×\(scale.factor)")
            #expect(scale(Size.sidebarWidth) - ActivityBar.width(scale) >= scale(420), "at ×\(scale.factor)")
        }
    }

    /// A hidden panel's icon leaves the bar; the gear stays.
    @Test func hiddenPanelsLeaveTheBar() throws {
        let (sidebar, _) = try sidebarModel()
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let (host, window) = hosted(sidebar, activity: activity, controls: nil)
        defer { window.close() }
        #expect(shown(ActivityBar.iconMarkName, in: host).count == ActivityPanel.allCases.count + 1)
        #expect(activity.setHidden(.metrics, true) && activity.setHidden(.git, true))
        #expect(activity.layout.visibleOrder == [.sessions, .files, .ssh])
        #expect(shown(ActivityBar.iconMarkName, in: host).count == 3 + 1, "a hidden panel’s icon is still drawn")
        activity.select(.metrics)
        #expect(activity.layout.selected == .sessions, "a hidden panel was shown")
    }

    /// A drop is counted in the shown panels: with Metrics hidden, the first icon dropped one cell
    /// down lands after Files, the second icon drawn.
    @Test func aDropCountsOnlyShownPanels() {
        let model = ActivityModel(source: ActivityOrderSource(defaults: nil))
        model.setHidden(.metrics, true)
        model.move(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(model.layout.visibleOrder == [.files, .sessions, .git, .ssh])
    }

    /// Hiding the panel two windows show switches each to the first panel still shown; a window
    /// showing another keeps it.
    @Test func hidingTheShownPanelShowsTheFirstLeft() {
        let source = ActivityOrderSource(defaults: nil)
        source.move(.files, before: .sessions)
        let first = ActivityModel(source: source), second = ActivityModel(source: source), third = ActivityModel(source: source)
        first.select(.sessions)
        second.select(.sessions)
        third.select(.git)
        #expect(first.setHidden(.sessions, true))
        #expect(first.layout.selected == .files && second.layout.selected == .files)
        #expect(third.layout.selected == .git)
    }

    @Test func theLastPanelCannotBeHidden() {
        let defaults = ScratchDefaults.make()
        let model = ActivityModel(defaults: defaults)
        for panel in [ActivityPanel.sessions, .metrics, .files, .git] { #expect(model.setHidden(panel, true)) }
        #expect(!model.setHidden(.ssh, true))
        #expect(model.layout.visibleOrder == [.ssh] && model.layout.selected == .ssh)
        #expect(ActivityHiddenStore.load(defaults) == ["sessions", "metrics", "files", "git"])
    }

    /// One hidden set for the app, saved on this Mac for the next launch.
    @Test func hiddenIsSharedAndSaved() {
        let defaults = ScratchDefaults.make()
        let source = ActivityOrderSource(defaults: defaults)
        let first = ActivityModel(source: source), second = ActivityModel(source: source)
        first.setHidden(.files, true)
        #expect(second.layout.hidden == [.files])
        #expect(ActivityHiddenStore.load(defaults) == ["files"])
        #expect(ActivityModel(defaults: defaults).layout.visibleOrder == [.sessions, .metrics, .git, .ssh], "a new window reads the saved set")
        second.setHidden(.files, false)
        #expect(first.layout.hidden.isEmpty)
        #expect(ActivityHiddenStore.load(defaults) == [])
    }

    @Test func unknownHiddenValuesAreIgnored() {
        let defaults = ScratchDefaults.make()
        ActivityHiddenStore.save(["svn", "git"], to: defaults)
        #expect(ActivityModel(defaults: defaults).layout.hidden == [.git])
    }

    /// View › Show …: a hidden panel has no item, so its ⌃⌘ key does nothing either.
    @Test func aHiddenPanelHasNoShowItem() {
        #expect(SidebarCommandMenu.panels(hidden: []).map(\.panel) == ActivityPanel.allCases)
        #expect(SidebarCommandMenu.panels(hidden: [.metrics, .ssh]).map(\.title) == ["Show Sessions", "Show Files", "Show Git"])
    }

    /// The titles of `items`, a divider as “-”.
    private func titles(_ items: [GearMenu.Item]) -> [String] { items.map { $0.title ?? "-" } }

    private func submenu(_ title: String, in items: [GearMenu.Item]) throws -> [GearMenu.Item] {
        try #require(items.first { $0.title == title }).children
    }

    /// The checked item's title in `items`.
    private func checked(_ items: [GearMenu.Item]) -> [String] {
        items.compactMap { if case .button(let title, true, _, _) = $0 { title } else { nil } }
    }

    /// VS Code's Manage menu: Settings…, Theme (the ten, or Light and Dark submenus while following
    /// the Mac, then the two toggles) and Customize (a Show toggle per panel, the last shown disabled).
    @Test func theGearMenuOffersSettingsThemesAndCustomize() throws {
        let names = ThemeCatalog.all.map(\.name)
        let single = ThemeChoice(followsMac: false, single: "dracula")
        var layout = ActivityLayout(saved: nil)
        let items = GearMenu.items(choice: single, match: true, layout: layout)
        #expect(titles(items) == ["Settings…", "-", "Theme", "Customize"])
        #expect(items.first == .button("Settings…", checked: nil, enabled: true, .openSettings))
        let theme = try submenu("Theme", in: items)
        #expect(titles(theme) == names + ["-", "Follow Mac Appearance", "Match Terminal"])
        #expect(checked(theme) == ["Dracula", "Match Terminal"])

        let following = GearMenu.items(choice: ThemeChoice(followsMac: true, light: "github-light", dark: "nord"), match: false, layout: layout)
        let followingTheme = try submenu("Theme", in: following)
        #expect(titles(followingTheme) == ["Light Theme", "Dark Theme", "-", "Follow Mac Appearance", "Match Terminal"])
        #expect(checked(followingTheme) == ["Follow Mac Appearance"])
        let light = try submenu("Light Theme", in: followingTheme), dark = try submenu("Dark Theme", in: followingTheme)
        #expect(titles(light) == ["Shellforge", "Light Modern", "GitHub Light", "Solarized Light"])
        #expect(titles(dark) == ["Shellforge", "Dark Modern", "One Dark", "Dracula", "GitHub Dark", "Solarized Dark", "Nord"])
        #expect(checked(light) == ["GitHub Light"] && checked(dark) == ["Nord"])

        for panel in [ActivityPanel.metrics, .files, .git] { layout.setHidden(panel, true) }
        let customize = try submenu("Customize", in: GearMenu.items(choice: single, match: false, layout: layout))
        #expect(titles(customize) == ["Show Sessions", "Show Metrics", "Show Files", "Show Git", "Show SSH"])
        #expect(customize[1] == .button("Show Metrics", checked: false, enabled: true, .showPanel(.metrics, true)))
        #expect(customize[0] == .button("Show Sessions", checked: true, enabled: true, .showPanel(.sessions, false)))
        layout.setHidden(.ssh, true)
        let last = try submenu("Customize", in: GearMenu.items(choice: single, match: false, layout: layout))
        #expect(last[0] == .button("Show Sessions", checked: true, enabled: false, .showPanel(.sessions, false)), "the last shown panel can be hidden")
    }

    /// A slot holding a theme of the other appearance checks Shellforge, as the Settings picker
    /// shows it and as it applies.
    @Test func aCrossedSlotChecksShellforgeInTheMenu() throws {
        let crossed = ThemeChoice(followsMac: true, light: "dracula", dark: "github-light")
        let theme = try submenu("Theme", in: GearMenu.items(choice: crossed, match: false, layout: ActivityLayout(saved: nil)))
        #expect(checked(try submenu("Light Theme", in: theme)) == ["Shellforge"])
        #expect(checked(try submenu("Dark Theme", in: theme)) == ["Shellforge"])
    }

    /// The gear's tooltip is VS Code's word; VoiceOver reads what it holds.
    @Test func theGearSaysWhatItHolds() {
        #expect(ActivityBar.gearHelp == "Manage")
        #expect(ActivityBar.gearLabel == "Settings, Theme and Customize")
    }

    /// A theme, Follow Mac and Match Terminal chosen from the menu are saved at once; Customize hides a panel.
    @Test func choosingAThemeFromTheMenuSavesIt() throws {
        let store = ScratchDefaults.make()
        let theme = ThemeSettings(defaults: store), match = TerminalMatchSettings(defaults: store)
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        var opened = 0
        func choose(_ path: [String]) throws {
            var items = GearMenu.items(choice: theme.choice, match: match.isOn, layout: activity.layout)
            for title in path.dropLast() { items = try submenu(title, in: items) }
            guard case .button(_, _, _, let action) = try #require(items.first { $0.title == path.last }) else {
                Issue.record("\(path) is not a button"); return
            }
            GearMenu.perform(action, theme: theme, terminalMatch: match, activity: activity, openSettings: { opened += 1 })
        }
        try choose(["Theme", "Dark Theme", "Dracula"])
        #expect(ThemeSettings(defaults: store).choice == ThemeChoice(followsMac: true, dark: "dracula"))
        try choose(["Theme", "Follow Mac Appearance"])
        try choose(["Theme", "Nord"])
        #expect(ThemeSettings(defaults: store).choice == ThemeChoice(followsMac: false, dark: "dracula", single: "nord"))
        try choose(["Theme", "Match Terminal"])
        #expect(TerminalMatchSettings(defaults: store).isOn)
        try choose(["Customize", "Show Git"])
        #expect(activity.layout.hidden == [.git])
        try choose(["Settings…"])
        #expect(opened == 1)
    }
}
