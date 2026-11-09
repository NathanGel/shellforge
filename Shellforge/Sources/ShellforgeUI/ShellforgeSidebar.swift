import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The sidebar on the left of a Shellforge window: projects → tasks → tabs.
@MainActor
public enum ShellforgeSidebar {
    /// Its width in points. The window's layout gives the session area what is left.
    public static let width: CGFloat = Size.sidebarWidth

    /// The view the window places at its left edge: as wide as the sidebar, and only its height
    /// follows the window's. `chooseFolder` asks the user for a project folder (an open panel);
    /// `hooks` is the app's Agent hooks sheet.
    /// `machine` is the app's one sampler of the Mac's readings, for the footer.
    /// `backpack` is the app's one Backpack Mode; `showBackpack` hands back how this sidebar opens
    /// its sheet, for the View menu's ⌘B. `hideSidebar` is the header's Hide Sidebar button: ⌃⌘S.
    /// `zoom` is the app's one text size, which every window's sidebar draws at; its sheets, in
    /// panels of their own, stay at `.standard`. `terminalMatch` is the app's one Settings › Core ›
    /// Terminal switch. `feedback` is the app's one feedback prompt, and `showFeedback` hands back how
    /// this sidebar opens the feedback form, for the Help menu. `panelCornerRadius`, when given, draws
    /// the sidebar as a floating panel with those corners (macOS 26); nil draws the classic sidebar.
    /// `agentTools` is what the app bundle gives the agents, for Settings › Agents, and
    /// `agentsChanged` is told each time Settings › Agents adds, changes or removes one.
    public static func makeView(model: SidebarModel, chooseFolder: @escaping @MainActor () -> String?, hooks: AgentHooksModel,
                                machine: MachineMonitor, backpack: BackpackController, zoom: SidebarZoom,
                                terminalMatch: TerminalMatchSettings, feedback: FeedbackPrompt, panelCornerRadius: CGFloat? = nil,
                                agentTools: AgentTools = .none, agentsChanged: @escaping @MainActor () -> Void = {},
                                showBackpack: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { _ in },
                                showFeedback: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { _ in },
                                hideSidebar: @escaping @MainActor () -> Void = {}) -> NSView {
        let chrome = SidebarChrome()
        chrome.panelCornerRadius = panelCornerRadius
        // The view owns the presenter, which holds the whole sidebar; `showBackpack` gets one that
        // reaches it weakly, so whatever keeps that — ⌘B's registry — never keeps the sidebar.
        let presenter = SheetPresenter()
        let feedbackPresenter = SheetPresenter()
        let sidebar = SidebarView(model: model, chooseFolder: chooseFolder, hooks: hooks, machine: machine,
                                  backpack: backpack, terminalMatch: terminalMatch, feedback: feedback,
                                  chrome: chrome, showBackpack: { [weak presenter] present in
            guard let presenter else { return }
            presenter.present = present
            showBackpack { [weak presenter] in presenter?.present?() }
        }, showFeedback: { [weak feedbackPresenter] present in
            guard let feedbackPresenter else { return }
            feedbackPresenter.present = present
            showFeedback { [weak feedbackPresenter] in feedbackPresenter?.present?() }
        }, hideSidebar: hideSidebar, agentTools: agentTools, agentsChanged: agentsChanged)
        let host = SidebarHostingView(rootView: ZoomedSidebar(zoom: zoom, sidebar: sidebar))
        host.chrome = chrome
        // Esc inside the sidebar, and hiding it (`willHide`), leave Rearrange mode unsaved.
        host.cancelRearrange = { [weak model] in
            guard let model, model.isRearranging else { return false }
            model.cancelRearrange()
            return true
        }
        host.backpackPresenter = presenter
        host.feedbackPresenter = feedbackPresenter
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        // The root view lays the sidebar out by hand. Flexible margins keep its floating inset from
        // becoming a minimum window height when the window's layout engine is engaged.
        host.autoresizingMask = [.height, .minYMargin, .maxYMargin]
        return host
    }

    /// Where the window's buttons sit inside the sidebar `view` (one `makeView` made), or nil while
    /// they are not inside it. The header moves onto their row.
    public static func setWindowControls(_ controls: SidebarWindowControls?, on view: NSView) {
        guard let host = view as? SidebarHostingView<ZoomedSidebar>, host.chrome?.windowControls != controls else { return }
        host.chrome?.windowControls = controls
    }

    /// The floating panel's corner radius in the sidebar `view`; it stays square where it was made
    /// without one (the sidebar does not float).
    public static func setPanelCornerRadius(_ radius: CGFloat, on view: NSView) {
        guard let host = view as? SidebarHostingView<ZoomedSidebar>, let chrome = host.chrome,
              chrome.panelCornerRadius != nil, chrome.panelCornerRadius != radius else { return }
        chrome.panelCornerRadius = radius
    }

    /// What `setPanelCornerRadius` last set on `view`.
    public static func panelCornerRadius(of view: NSView) -> CGFloat? {
        (view as? SidebarHostingView<ZoomedSidebar>)?.chrome?.panelCornerRadius
    }

    /// What `setWindowControls` last set on `view`.
    public static func windowControls(of view: NSView) -> SidebarWindowControls? {
        (view as? SidebarHostingView<ZoomedSidebar>)?.chrome?.windowControls
    }

    /// How far the sidebar's list insets its rows: what lines the host's toggle up with them.
    public static var listInset: CGFloat { SidebarRowLayout.listInset }

    /// The user is hiding the sidebar `view` (⌃⌘S, its button, the window's toggle): Rearrange mode
    /// is cancelled, so nothing is left half-arranged where it cannot be seen. Not for a revealed
    /// sidebar sliding away again: that is not a hide the user asked for.
    public static func willHide(_ view: NSView) {
        _ = (view as? RearrangeCancelling)?.cancelRearrange?()
    }

    /// Whether `view` is a sidebar `makeView` made, or inside one.
    public static func contains(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return sequence(first: view, next: \.superview).contains { $0 is SidebarHostingView<ZoomedSidebar> }
    }
}

// FooterClock and SidebarFooterHost: ported from AiTerm (app/Sources/AiTerm/Views/SidebarView.swift), GPLv3, Laurens D'Hondt.

/// The instant and calendar the usage footer reads its reset times against. Unset, the footer uses
/// the wall clock and the user's calendar; a test pins both so the labels it draws do not move with
/// the time of day, the weekday or the machine's time zone. (AiTerm's `FooterClock`.)
struct FooterClock {
    var now: Date
    var calendar: Calendar
}

private struct FooterClockKey: EnvironmentKey { static let defaultValue: FooterClock? = nil }

extension EnvironmentValues {
    var footerClock: FooterClock? {
        get { self[FooterClockKey.self] }
        set { self[FooterClockKey.self] = newValue }
    }
}

/// AiTerm's `SidebarFooterHost`: the vendor rows recomputed on the minute — a window that has reset
/// is dropped, and a reset time gains its weekday across midnight — and the selected row's context
/// and the Mac's readings over them.
struct SidebarFooterHost: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var hooks: AgentHooksModel
    @ObservedObject var machine: MachineMonitor
    @ObservedObject var backpack: BackpackController
    let toggleMac: () -> Void
    let openMacSettings: () -> Void
    @Environment(\.footerClock) private var footerClock

    @Environment(\.interfaceScale) private var scale

    var body: some View {
        TimelineView(.everyMinute) { context in
            SidebarFooter(task: model.footerRow,
                          rows: model.vendorRows(now: footerClock?.now ?? context.date, calendar: footerClock?.calendar ?? .current,
                                                 claudeStatusLineInstalled: hooks.claudeStatusLineInstalled),
                          machine: machine.lines,
                          mac: MacModePresentation.line(mode: MacMode(state: backpack.state, transition: backpack.transition),
                                                        hotspot: backpack.network, wifi: backpack.currentNetwork),
                          toggleMac: toggleMac, openMacSettings: openMacSettings)
        }
        // The footer on a rounded card, inside its own frame, so the footer's geometry is unchanged;
        // its edges in line with the rows' pills, at the list's inset.
        .background {
            RoundedRectangle(cornerRadius: scale(Radius.group), style: .continuous)
                .fill(Palette.footerCard)
                .padding(.horizontal, SidebarRowLayout.listInset)
                .padding(.bottom, scale(Space.base))
        }
    }
}

/// The sidebar at the app's text size, redrawn when ⌘+ / ⌘− changes it.
struct ZoomedSidebar: View {
    @ObservedObject var zoom: SidebarZoom
    let sidebar: SidebarView

    var body: some View { sidebar.interfaceScale(zoom.scale) }
}

/// The sidebar's right edge: one hairline, so the sidebar reads apart from the terminal beside it.
/// `Hairline` is horizontal and AiTerm's (TokenParityTests); this is its vertical twin.
struct SidebarEdge: View {
    var body: some View {
        Rectangle().fill(Palette.border).frame(width: 1)
    }
}

/// What the sidebar is drawn on: the floating panel — a rounded `MaterialBackground` with a hairline
/// outline — or, classic, the sidebar material filling its column. Either runs under the title bar,
/// so it ignores the safe area the content keeps to.
struct SidebarGround: View {
    let cornerRadius: CGFloat?
    /// This Mac's material; a test names one.
    var kind: ShellforgeMaterial.Kind = ShellforgeMaterial.current

    var body: some View {
        Group {
            if let cornerRadius {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                MaterialBackground(shape, kind: kind)
                    .overlay { shape.strokeBorder(Palette.border, lineWidth: 1) }
            } else {
                // Glass is for the floating panel; a flush sidebar takes the sidebar material.
                MaterialBackground(Rectangle(), kind: kind == .glass ? .sidebar : kind)
            }
        }
        .ignoresSafeArea()
    }
}

/// The sidebar's host: where `NativeRowHighlight` stops looking for its list.
final class SidebarHostingView<Content: View>: NSHostingView<Content>, RowHighlightBoundary {
    /// A floating sidebar's window moves by its background; a click in the sidebar is the
    /// sidebar's, never the start of a window drag.
    override var mouseDownCanMoveWindow: Bool { false }
    /// The share of the window's chrome the sidebar draws by.
    var chrome: SidebarChrome?
    /// How this sidebar opens its Backpack sheet: owned here, so it goes with the view.
    var backpackPresenter: SheetPresenter?
    /// How this sidebar opens its feedback form.
    var feedbackPresenter: SheetPresenter?
    var cancelRearrange: (@MainActor () -> Bool)?

    /// Esc, with the keyboard in the sidebar: cancels Rearrange mode. A responder action, so it
    /// reaches here only from a view inside the sidebar, never from the terminal beside it.
    override func cancelOperation(_ sender: Any?) {
        if cancelRearrange?() != true { super.cancelOperation(sender) }
    }
}

/// A sidebar host that can leave Rearrange mode: Esc inside it, or the user hiding it.
@MainActor
protocol RearrangeCancelling: AnyObject {
    /// Cancels the mode; false when it was not on.
    var cancelRearrange: (@MainActor () -> Bool)? { get }
}

extension SidebarHostingView: RearrangeCancelling {}

/// Calls back once when a window closes, unless stopped first: how a sheet learns it was closed
/// rather than answered. The panel's own buttons stop it.
@MainActor
final class CloseWatch {
    private var tokens: [NSObjectProtocol] = []

    func start(on windows: [NSWindow?], then closed: @escaping @MainActor () -> Void) {
        stop()
        tokens = windows.compactMap { $0 }.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop(); closed() }
            }
        }
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }
}

/// A sidebar's way to open one of its sheets, kept by its view (`ShellforgeSidebar.makeView`).
@MainActor
final class SheetPresenter {
    var present: (@MainActor () -> Void)?
}

/// AiTerm's sidebar, inside iTerm2's window: the PROJECTS header, each project with its tasks and
/// the selected task's tabs, the tabs of no task, the banners, or the empty state.
struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let chooseFolder: @MainActor () -> String?
    @ObservedObject var hooks: AgentHooksModel
    let machine: MachineMonitor
    let backpack: BackpackController
    let terminalMatch: TerminalMatchSettings
    let feedback: FeedbackPrompt
    @ObservedObject var chrome: SidebarChrome
    let showBackpack: @MainActor (@escaping @MainActor () -> Void) -> Void
    let showFeedback: @MainActor (@escaping @MainActor () -> Void) -> Void
    let hideSidebar: @MainActor () -> Void
    let agentTools: AgentTools
    let agentsChanged: @MainActor () -> Void
    /// The window the sidebar is drawn in, which the Agent hooks panel hangs from.
    @State private var anchor = WindowAnchor()
    @State private var sheet = PanelSlot()
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            // With the window's buttons inside the panel, the header is their row, pinned. Rearrange
            // mode's bar takes the header's place, pinned either way, so Done stays in reach.
            if model.isRearranging {
                RearrangeBar(cancel: model.cancelRearrange, done: model.finishRearrange, windowControls: chrome.windowControls)
            } else if let controls = chrome.windowControls {
                header(controls)
            }
            // Its buttons wait while the sidebar is rearranged.
            SidebarBanners(model: model, feedback: feedback, giveFeedback: presentFeedback)
                .allowsHitTesting(!model.isRearranging)
            List {
                if chrome.windowControls == nil && !model.isRearranging { header(nil) }
                ForEach(model.rows) { row in rowView(row) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(NativeRowHighlight.off)
            .environment(\.isRearranging, model.isRearranging)
            .rearrangeListDrop(model)
            SidebarFooterHost(model: model, hooks: hooks, machine: machine, backpack: backpack,
                              toggleMac: { BackpackToggle(backpack: backpack, presentSheet: presentBackpack).run() },
                              openMacSettings: showMacSettings)
        }
        // The header places itself on the buttons' row, so the title bar's safe area is not wanted.
        .ignoresSafeArea(.container, edges: chrome.windowControls == nil ? [] : .top)
        .overlay(alignment: .trailing) { if chrome.panelCornerRadius == nil { SidebarEdge() } }
        // As wide as its panel and no wider: the window keeps the sidebar to its narrowest, and a
        // minimum here — scaled with the zoom — spilled the content past a narrower panel's edges.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { SidebarGround(cornerRadius: chrome.panelCornerRadius) }
        .surface(.sidebar)
        .tint(Palette.accent)
        .background(WindowReader(anchor: anchor))
        // The View menu's ⌘B opens the sheet on the key window's sidebar: this one says how.
        .onAppear { showBackpack(presentBackpack); showFeedback(presentFeedback) }
        // The Tasks menu's keys that need a sheet: shown as the "+" or the row's menu would.
        .onReceive(model.sheetRequests) { request in
            switch request {
            case .newTask(let project): showNewTask(in: project)
            case .newReview(let project): showNewReview(in: project)
            case .addProject: addProject()
            case .removeTask(let task): Task { await model.confirmRemove(taskId: task) }
            case .closeLastTab(let task, let tab, let paneOnly):
                Task { await model.confirmCloseLastTab(taskId: task, tab: tab, paneOnly: paneOnly) }
            case .newTerminal(let project): showNewTerminal(in: project)
            case .addDivider: showAddDivider()
            }
        }
    }

    private func header(_ controls: SidebarWindowControls?) -> SidebarHeader {
        SidebarHeader(addProject: addProject, addDivider: showAddDivider, canAddDivider: model.can(.addDivider),
                      showHooks: showHooks, showMacSettings: showMacSettings, newHomeTab: { model.openHomeTab() }, hideSidebar: hideSidebar,
                      windowControls: controls)
    }

    /// A row as drawn: in Rearrange mode, behind its handle and taking drops (RearrangeRow).
    @ViewBuilder private func rowView(_ row: SidebarRow) -> some View {
        if model.isRearranging, let item = RearrangeDrop.item(of: row) {
            RearrangeRow(model: model, item: item, id: row.id, label: Self.rearrangeLabel(row)) { rowContent(row) }
                .listRowSeparator(.hidden)
        } else {
            rowContent(row)
        }
    }

    /// What VoiceOver calls a row in Rearrange mode.
    private static func rearrangeLabel(_ row: SidebarRow) -> String {
        switch row {
        case .project(let node, _): node.project.name
        case .divider(let row): row.divider.name.isEmpty ? "Divider" : "\(row.divider.name) divider"
        case .tunnel(let row): "Tunnel \(row.alias)"
        case .task(let node, _): node.task.title
        case .terminal(let node, _): node.terminal.name
        case .empty, .tab, .otherTabsHeading: ""
        }
    }

    @ViewBuilder private func rowContent(_ row: SidebarRow) -> some View {
        let canRearrange = model.canRearrange
        switch row {
        case .empty:
            SidebarEmptyState(canAdd: true, add: addProject).listRowSeparator(.hidden)
        case .project(let node, let collapsed):
            ProjectHeaderRow(node: node, collapsed: collapsed, provider: model.providers[node.id] ?? .git,
                             statuses: node.tasks.map { model.status(ofTask: $0.id) } + node.terminals.map { model.status(ofTerminal: $0.id) },
                             toggle: { model.toggleCollapsed(node.id) },
                             newTask: { showNewTask(in: node.id) },
                             newReview: { showNewReview(in: node.id) },
                             newTerminal: { showNewTerminal(in: node.id) },
                             canRearrange: canRearrange, rearrange: model.beginRearrange,
                             editJiraProjects: { showJiraProjects(for: node.id) },
                             editTunnels: { showTunnels(for: node.id) },
                             editSSHHost: { showSSHHost(for: node.id) },
                             openSSHHost: { Task { await model.openSSHHost(of: node.id) } },
                             canOpenSSHHost: model.canOpenSSHHost(of: node.id),
                             remove: { Task { await model.confirmRemove(project: node.id) } },
                             pullTitle: SidebarModel.offersPull(model.providers[node.id] ?? .git)
                                 ? SidebarModel.pullTitle(branch: model.defaultBranch(of: node.id)) : nil,
                             pulling: model.isPulling(node.id),
                             pull: { Task { await model.pullDefault(project: node.id) } })
                .listRowSeparator(.hidden)
        case .terminal(let node, let selected):
            TerminalRowView(node: node, selected: selected, agents: model.avatars(forTerminal: node.id),
                            status: model.status(ofTerminal: node.id), guessed: model.statusIsGuessed(ofTerminal: node.id),
                            agentName: model.agentName, activate: { model.select(terminal: node.id) },
                            rename: { showRenameTerminal(node.terminal) }, remove: { model.removeTerminal(node.id) },
                            menuExtras: AnyView(OpenInMenuItems(folder: model.project(node.terminal.projectId)?.path ?? "")),
                            canRearrange: canRearrange, rearrange: model.beginRearrange)
                .listRowSeparator(.hidden)
        case .divider(let row):
            DividerRow(row: row, rename: { showRenameDivider(row.divider) }, canRearrange: canRearrange, rearrange: model.beginRearrange,
                       remove: { model.removeDivider(row.divider.id) })
                .listRowSeparator(.hidden)
        case .tunnel(let tunnel):
            TunnelRowView(row: tunnel, start: { model.startTunnel(tunnel.alias) }, stop: { model.stopTunnel(tunnel.alias) },
                          answerInTab: { model.answerInTab(tunnel.alias, in: tunnel.projectId) },
                          canRearrange: canRearrange, rearrange: model.beginRearrange)
                .listRowSeparator(.hidden)
        case .task(let node, let selected):
            TaskRowView(node: node, selected: selected, agents: model.avatars(forTask: node.id),
                        status: model.status(ofTask: node.id), guessed: model.statusIsGuessed(ofTask: node.id), agentName: model.agentName,
                        removal: model.removals[node.id],
                        activate: { model.select(task: node.id) },
                        remove: { Task { await model.confirmRemove(taskId: node.id) } },
                        rename: { showRename(.task, name: node.task.title) { model.renameTask(node.id, to: $0) } },
                        closeTab: { model.closeCurrentTab(ofTask: node.id) }, closeTitle: model.closeTitle(ofTask: node.id),
                        diff: model.diffs[node.id], canRearrange: canRearrange, rearrange: model.beginRearrange)
                .listRowSeparator(.hidden)
        case .tab(let tab, let selected):
            TabRowView(tab: tab, selected: selected, agents: model.avatars(forTab: tab.id),
                       status: model.status(ofTab: tab.id), guessed: model.statusIsGuessed(ofTab: tab.id), agentName: model.agentName,
                       activate: { model.select(tab: tab.id) },
                       close: { model.closeTab(tab.id) }, closeTitle: model.closeTitle(ofTab: tab.id))
                .listRowSeparator(.hidden)
        case .otherTabsHeading:
            SidebarHeading("Other Tabs")
                .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base))
                .listRowSeparator(.hidden)
        }
    }

    /// AiTerm's Backpack sheet, in the sidebar's one panel.
    private func presentBackpack() {
        sheet.present(over: anchor.window) { dismiss in BackpackSheet(model: BackpackSheetModel(backpack: backpack), dismiss: dismiss) }
    }

    /// The feedback form, in the sidebar's one panel. Closing its window any other way than its own
    /// buttons is a cancel, so a send under way stops and the prompt hears it was not sent.
    private func presentFeedback() {
        let watch = CloseWatch()
        sheet.present(over: anchor.window) { dismiss in
            let model = FeedbackFormModel.live(prompt: feedback) { watch.stop(); dismiss() }
            watch.start(on: [anchor.window], then: model.cancel)
            return FeedbackSheet(model: model)
        }
    }

    /// The Mac card — what Backpack Mode needs from this Mac — in a panel of its own with Done, until
    /// Shellforge has a Settings window to hold it (AiTerm's Settings › Integrations › Mac).
    private func showMacSettings() {
        let integrations = IntegrationSettingsModel(jira: model.jiraSettings(), gitLab: model.gitLabSettings(),
                                                    gitHub: model.gitHubSettings())
        let environment = model.environmentModel()
        let agentDefaults = model.agentDefaultsModel()
        // The agents' secrets live in the Keychain, and nowhere else.
        let agents = AgentListModel(registry: AgentRegistry(readyMade: agentTools.readyMade), secrets: Keychain.shared,
                                    launcher: model.launcher, tasks: { [model] in model.document.workspace.tasks },
                                    prompter: model.prompter, tools: agentTools, store: model.$sessions.eraseToAnyPublisher(),
                                    changed: agentsChanged)
        sheet.present(over: anchor.window) { dismiss in
            SettingsPanel(backpack: backpack, integrations: integrations, environment: environment, terminalMatch: terminalMatch, feedback: feedback,
                          agentDefaults: agentDefaults, agents: agents, close: dismiss)
        }
    }

    /// The Agent hooks sheet, in its own dark panel on the sidebar's window.
    private func showHooks() {
        sheet.present(over: anchor.window) { dismiss in AgentHooksView(model: hooks, dismiss: dismiss) }
    }

    private func addProject() {
        if let folder = chooseFolder() { Task { await model.addProject(folder: folder) } }
    }

    /// The sheet that edits a project's linked Jira projects, opened on the list as it is now.
    private func showJiraProjects(for id: UUID) {
        guard let project = model.project(id) else { return }
        sheet.present(over: anchor.window) { dismiss in
            JiraProjectSheet(projectName: project.name, linked: project.jiraProjects, canSubmit: true,
                             loadProjects: model.loadJiraProjects,
                             submit: { model.setJiraProjects($0, on: id) }, dismiss: dismiss)
        }
    }

    /// The sheet that edits a project's tunnels, opened on the list as it is now; the config is read
    /// again for it, off the main actor.
    private func showTunnels(for id: UUID) {
        guard let project = model.project(id) else { return }
        sheet.present(over: anchor.window) { dismiss in
            TunnelsSheet(projectName: project.name, linked: project.tunnels, loadHosts: model.loadSSHHosts,
                         submit: { model.setTunnels($0, on: id) }, dismiss: dismiss)
        }
    }

    /// The sheet that names a project's SSH host; the config is read again for it.
    private func showSSHHost(for id: UUID) {
        guard let project = model.project(id) else { return }
        sheet.present(over: anchor.window) { dismiss in
            SSHHostSheet(projectName: project.name, current: project.sshHost, loadHosts: model.loadSSHHosts,
                         submit: { model.setSSHHost($0, on: id) }, dismiss: dismiss)
        }
    }

    /// AiTerm's New terminal sheet: the row's name, prefilled with the suggestion.
    private func showNewTerminal(in id: UUID) {
        guard let project = model.project(id) else { return }
        let suggested = model.suggestedTerminalName(in: id)
        sheet.present(over: anchor.window) { dismiss in
            NameSheet.newTerminal(projectName: project.name, suggestedName: suggested,
                                  create: { model.newTerminal(name: $0, in: id) }, dismiss: dismiss)
        }
    }

    /// AiTerm's Add divider: an empty name is a plain rule.
    private func showAddDivider() {
        sheet.present(over: anchor.window) { dismiss in
            NameSheet(title: "Add divider", subtitle: "Groups the projects under it in the sidebar.", fieldLabel: "Divider name",
                      placeholder: "Work", help: "Leave it empty for a plain rule.", confirmLabel: "Add Divider", initialName: "",
                      submit: { model.addDivider(name: $0) }, dismiss: dismiss)
        }
    }

    private func showRenameDivider(_ divider: SidebarDivider) {
        sheet.present(over: anchor.window) { dismiss in
            NameSheet(title: RenameCopy.divider.title, subtitle: RenameCopy.divider.subtitle, fieldLabel: RenameCopy.divider.field,
                      placeholder: divider.name, confirmLabel: "Rename", initialName: divider.name,
                      submit: { model.renameDivider(divider.id, to: $0) }, dismiss: dismiss)
        }
    }

    private func showRenameTerminal(_ terminal: TerminalItem) {
        sheet.present(over: anchor.window) { dismiss in
            NameSheet(title: RenameCopy.terminal.title, subtitle: RenameCopy.terminal.subtitle,
                      fieldLabel: RenameCopy.terminal.field, placeholder: terminal.name, confirmLabel: "Rename", initialName: terminal.name,
                      submit: { model.renameTerminal(terminal.id, to: $0) }, dismiss: dismiss)
        }
    }

    /// AiTerm's Rename sheet with `copy`, opened on the row's current name.
    private func showRename(_ copy: RenameCopy, name: String, submit: @escaping (String) -> Void) {
        sheet.present(over: anchor.window) { dismiss in
            NameSheet(title: copy.title, subtitle: copy.subtitle, fieldLabel: copy.field, placeholder: name,
                      confirmLabel: "Rename", initialName: name, submit: submit, dismiss: dismiss)
        }
    }

    /// AiTerm's New Review sheet, in the sidebar's one panel: prepared off the main actor first — the
    /// project's remote and the connections are read for its search.
    private func showNewReview(in project: UUID) {
        Task { @MainActor in
            guard let review = await model.makeReviewModel(for: project) else { return }
            sheet.present(over: anchor.window) { dismiss in NewReviewSheet(model: review, dismiss: dismiss) }
        }
    }

    /// AiTerm's New Task sheet, in its own dark panel on the sidebar's window; one at a time.
    private func showNewTask(in project: UUID) {
        Task { @MainActor in
            guard let newTask = await model.prepareNewTask(for: project) else { return }
            sheet.present(over: anchor.window) { dismiss in NewTaskSheet(model: newTask, dismiss: dismiss) }
        }
    }
}
