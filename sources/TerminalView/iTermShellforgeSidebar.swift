//
//  iTermShellforgeSidebar.swift
//  Shellforge
//
//  Hands the Shellforge sidebar, which lives in the Shellforge package, to the Objective-C window
//  code, and implements its TerminalHost over one PseudoTerminal's tabs.
//

import AppKit
import Combine
import ShellforgeCore
import ShellforgeUI

@objc(iTermShellforgeSidebar)
@MainActor
final class iTermShellforgeSidebar: NSObject {

    /// One shared launcher, so the login shell's environment is read once per app run.
    nonisolated static let launcher = CommandLauncher()

    /// The Agent hooks sheet every window's sidebar opens: the hooks bundled in
    /// `Contents/Resources/hooks`, installed into the user's home only on a click.
    static let hooks = AgentHooksModel(integrations: HookIntegrations(resources: .bundled(resourceURL: Bundle.main.resourceURL)),
                                       names: Dictionary(uniqueKeysWithValues: AgentPresets.all.map { ($0.id, $0.name) }))

    /// The Mac's cpu, ram and battery for every window's footer, sampled every five seconds while
    /// the helper runs.
    static let machine = MachineMonitor(sensor: LiveMachineSensor(), power: IOKitPowerSource())

    /// AiTerm's Backpack Mode, one for the app: lid sleep through the sudoers rule the Mac card's
    /// Allow… installs, the iPhone's hotspot through CoreWLAN. Its toasts go to every sidebar's banner.
    static let backpack = BackpackController(
        ports: BackpackPorts.live(),
        settings: BackpackSettings(defaults: .standard, secrets: Keychain(service: "io.github.nathangel.shellforge")),
        agentsWorking: { link.store.sessions.values.contains { $0.state == .working } },
        openLocationSettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        },
        toast: { message in for model in sidebars.allObjects { model.lastError = message } })

    /// Every window's sidebar model, for Backpack's toasts.
    private static let sidebars = NSHashTable<SidebarModel>.weakObjects()
    /// How each window's sidebar opens the Backpack sheet, for ⌘B.
    private static let backpackSheets = BackpackSheets()

    /// The View menu's Backpack Mode (⌘B): AiTerm's toggle, the sheet on the key window's sidebar.
    @objc static func toggleBackpack(_ sender: Any?) {
        // A panel of ours (the sheet, Mac Settings) may be key: its parent window is the one meant.
        let window = NSApp.keyWindow.map { $0.sheetParent ?? $0 } ?? NSApp.mainWindow
        let terminal = window?.windowController as? PseudoTerminal ?? iTermController.sharedInstance()?.currentTerminal
        BackpackToggle(backpack: backpack, presentSheet: { backpackSheets.present(for: terminal) }).run()
    }

    /// The menu item's checkmark.
    @objc static func backpackIsOn() -> Bool { backpack.isOn }

    /// Every agent's model list, read from the user's own home.
    nonisolated static let catalogue = ModelCatalogue(home: FileManager.default.homeDirectoryForCurrentUser, launcher: launcher)

    /// The one workspace every window's sidebar shows and changes.
    static let document = WorkspaceDocument(store: WorkspaceStore())

    /// A new sidebar for `windowController`'s window.
    @objc static func makeView(for windowController: PseudoTerminal) -> NSView {
        let host = iTermShellforgeHost(windowController: windowController)
        // Read for each new window: an agent file added since shows in that window's New Task.
        let loaded = AgentFiles.load(AgentRegistry())
        let model = SidebarModel(host: host, document: document, launcher: launcher, feed: link,
                                 agents: loaded.agents, catalogue: { try catalogue.models(for: $0) }, sshConfig: .user)
        if let problem = loaded.problem { model.lastError = problem }
        model.prompter = ModalPrompter()
        windows.add(model, for: windowController)
        model.onEnvironmentReloaded = { environmentChanged() }
        sidebars.add(model)
        return ShellforgeSidebar.makeView(model: model, chooseFolder: FolderChooser.choose, hooks: hooks, machine: machine,
                                          backpack: backpack, showBackpack: { [weak windowController] present in
            if let windowController { backpackSheets.register(windowController, present) }
        })
    }

    /// The default profile changed to run the login shell in `directory`.
    /// `initialText` is typed into the shell once it starts — the task's agent — already escaped for
    /// iTerm2's interpolated-string evaluator (`TabCommand.initialText`).
    /// A profile key PTYSession reads: its initial text is sent once, then cleared from the
    /// session, so a split or a new tab copying the session's profile does not run the agent again.
    @objc nonisolated static let initialTextOnceKey = "Shellforge Initial Text Once"

    nonisolated static func taskTabProfile(base: [AnyHashable: Any], directory: String, initialText: String? = nil) -> [AnyHashable: Any] {
        var profile = base
        if let initialText {
            profile[KEY_INITIAL_TEXT] = initialText
            profile[initialTextOnceKey] = true
        }
        profile[KEY_CUSTOM_COMMAND] = "No"
        profile[KEY_CUSTOM_DIRECTORY] = kProfilePreferenceInitialDirectoryCustomValue
        profile[KEY_WORKING_DIRECTORY] = directory
        return profile
    }
}

/// `TerminalHost` for one window: its tabs, read live from iTerm2, tagged by user variables.
@MainActor
final class iTermShellforgeHost: TerminalHost {
    private weak var windowController: PseudoTerminal?
    var onChange: (@MainActor @Sendable () -> Void)?
    var onSplitRefused: (@MainActor @Sendable (String) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(windowController: PseudoTerminal) {
        self.windowController = windowController
        let names: [Notification.Name] = [
            .PTYSessionCreated,
            .PTYSessionTerminated,
            .PTYSessionPresentationNameDidChange,
            .iTermTabDidClose,
            .init(iTermSelectedTabDidChange),
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Session-created fires before the session joins a tab: the window is read next turn,
                // once for every notification of this one (titles change several times a second).
                MainActor.assumeIsolated {
                    self?.changes.signal()
                    // A tab opened, closed or moved: the daemon hears it now, not on the next tick.
                    Self.reports.signal()
                }
            })
        }
    }

    private lazy var changes = ChangeCoalescer { [weak self] in
        self?.joinPanes()
        self?.onChange?()
    }
    /// One for the app: every window's host signals it, and one list is read and sent.
    private static let reports = ChangeCoalescer { iTermShellforgeSidebar.link.reportsMayHaveChanged() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var tabs: [TabSnapshot] {
        (windowController?.tabs() ?? []).compactMap { tab in
            guard let session = tab.activeSession else { return nil }
            // Every pane's tags, the focused one first: a split focused beside the pane that opened
            // the task's tab has none, and must not move the tab out of its task.
            let panes = [session] + tab.sessions().filter { $0 !== session }
            let tags = TabSnapshot.tags(ofPanes: panes.map {
                ($0.genericScope.value(forVariableName: ShellforgeTags.task) as? String,
                 $0.genericScope.value(forVariableName: ShellforgeTags.project) as? String)
            })
            let terminal = TabSnapshot.terminal(ofPanes: panes.map { $0.genericScope.value(forVariableName: ShellforgeTags.terminal) as? String })
            return TabSnapshot(id: session.guid, tabId: Int(tab.uniqueId), title: session.name, taskId: tags.task, projectId: tags.project,
                               terminalId: terminal, paneCount: panes.count)
        }
    }

    var selectedTabId: String? { windowController?.currentTab()?.activeSession?.guid }

    func select(tab id: String) {
        guard let tab = windowController?.tabs().first(where: { $0.activeSession?.guid == id }),
              let item = tab.tabViewItem else { return }
        item.tabView?.selectTabViewItem(item)
        onChange?()
    }

    /// Every window's tabs, not only this one's: a task's tabs can be anywhere. `closeTab:` closes
    /// without asking, as AiTerm's removal closes the task's window.
    func closeTabs(ofTask id: UUID) -> Bool {
        let windows = (iTermController.sharedInstance()?.terminals() ?? []) as [PseudoTerminal]
        let closed = TaskTabs.close(taskId: id, in: windows, tabs: { $0.tabs() }, paneTags: { tab in
            tab.sessions().map { $0.genericScope.value(forVariableName: ShellforgeTags.task) as? String }
        }, keep: Self.keepOpen, close: { window, tab in window.close(tab) })
        onChange?()
        return closed
    }

    /// A terminal row's tab: a plain shell in `directory`, tagged with the terminal and its project.
    func openTab(in directory: String, terminalId: UUID, projectId: UUID, title: String) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        var profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory)
        profile[KEY_NAME] = title
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: { session in
            session.genericScope.setValue(terminalId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.terminal)
            session.genericScope.setValue(projectId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.project)
        }, completion: { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        })
    }

    /// The tab holding session `id`, in any window, closed as iTerm2's Close Tab closes it: a running
    /// job asks first.
    @discardableResult
    func close(tab id: String) -> Bool {
        let windows = (iTermController.sharedInstance()?.terminals() ?? []) as [PseudoTerminal]
        for window in windows {
            for tab in window.tabs() where tab.sessions().contains(where: { $0.guid == id }) {
                let closed = TaskTabs.closeOne(tab, in: window, tabs: { $0.tabs() }, keep: Self.keepOpen,
                                               close: { window, tab in _ = window.closeTabIfConfirmed(tab) })
                onChange?()
                return closed
            }
        }
        return false
    }

    /// iTerm2 closes a window with its last tab, and the sidebar with it: the window gets iTerm2's
    /// own new tab first — the default profile in its default folder, never the folder of a tab
    /// about to close (a worktree being deleted). Added at once, before any close runs.
    static func keepOpen(_ window: PseudoTerminal) -> Bool {
        guard let profile = ProfileModel.sharedInstance()?.defaultBookmark() else { return false }
        return window.createTab(withProfile: profile, withCommand: nil, environment: nil, tabIndex: nil,
                                previousDirectory: nil, parent: nil, completion: nil) != nil
    }

    /// Every window's panes tagged with the task.
    func paneCount(ofTask id: UUID) -> Int {
        let tag = id.uuidString.lowercased()
        let windows = (iTermController.sharedInstance()?.terminals() ?? []) as [PseudoTerminal]
        return windows.flatMap { $0.tabs() }.flatMap { $0.sessions() }
            .filter { ($0.genericScope.value(forVariableName: ShellforgeTags.task) as? String) == tag }.count
    }

    /// The focused pane of the tab holding session `id`, closed as iTerm2's Close closes it: a
    /// running job asks first. An unsplit tab closes as Close Tab does.
    @discardableResult
    func closePane(ofTab id: String) -> Bool {
        let windows = (iTermController.sharedInstance()?.terminals() ?? []) as [PseudoTerminal]
        for window in windows {
            for tab in window.tabs() where tab.sessions().contains(where: { $0.guid == id }) {
                guard tab.sessions().count > 1, let pane = tab.activeSession else { return close(tab: id) }
                let closed = window.closeSession(withConfirmation: pane)
                onChange?()
                return closed
            }
        }
        return false
    }

    /// A pane split off a task's or a terminal's (⌘D) carries no tag: it takes its tab's, so the
    /// tab stays the task's whichever pane closes first.
    func joinPanes() {
        for tab in windowController?.tabs() ?? [] {
            let sessions: [PTYSession] = tab.sessions()
            for name in [ShellforgeTags.task, ShellforgeTags.project, ShellforgeTags.terminal] {
                let tags = sessions.map { $0.genericScope.value(forVariableName: name) as? String }
                guard let tag = TaskTabs.joining(tags) else { continue }
                for (session, existing) in zip(sessions, tags) where existing == nil {
                    session.genericScope.setValue(tag, forVariableNamed: name)
                }
            }
        }
    }

    /// Every window's tabs of the terminal, closed without asking: nothing on disk goes with them.
    func closeTabs(ofTerminal id: UUID) -> Bool {
        let windows = (iTermController.sharedInstance()?.terminals() ?? []) as [PseudoTerminal]
        let closed = TaskTabs.close(taskId: id, in: windows, tabs: { $0.tabs() }, paneTags: { tab in
            tab.sessions().map { $0.genericScope.value(forVariableName: ShellforgeTags.terminal) as? String }
        }, keep: Self.keepOpen, close: { window, tab in window.close(tab) })
        onChange?()
        return closed
    }

    /// A tab of no task — a tunnel answered in a tab — running `command` in `directory`.
    func openTab(in directory: String, title: String, command: String) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        var profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory,
                                                            initialText: TabCommand.initialText(command))
        profile[KEY_NAME] = title
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: nil, completion: { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        })
    }

    /// The tunnels' ports are exported before the command, in the line typed into the shell: an
    /// iTerm2 profile has no environment of its own to carry them.
    /// `beside`, when given, runs in a pane split off to the right of the agent's, in the same folder.
    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String, command: String?, environment: [String: String],
                 beside: String?) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        let profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory,
                                                            initialText: TabCommand.exporting(environment, then: command).map(TabCommand.initialText))
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: { session in
            session.genericScope.setValue(taskId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.task)
            session.genericScope.setValue(projectId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.project)
        }, completion: { [weak self] session, ok in
            MainActor.assumeIsolated {
                self?.onChange?()
                guard let beside else { return }
                guard ok else { self?.onSplitRefused?(title); return }
                self?.split(session, running: beside, in: directory, base: base, title: title)
            }
        })
    }

    /// The pane beside a task's agent: a vertical split after it, typing `command` in `directory`.
    /// iTerm2 can refuse a split (a tmux tab, a window too small): the task stays open, and says so.
    private func split(_ session: PTYSession, running command: String, in directory: String, base: [AnyHashable: Any], title: String) {
        let profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory, initialText: TabCommand.initialText(command))
        // The agent's tab, which need not be the current one by now.
        guard let windowController, let tab = windowController.tab(for: session),
              windowController.canSplitPaneVertically(true, withBookmark: profile, in: tab) else {
            onSplitRefused?(title)
            return
        }
        // The split can fail twice over: no pane made (completion), or its shell not launched (ready).
        // Said once.
        let refusal = SplitRefusal { [weak self] in self?.onSplitRefused?(title) }
        windowController.asyncSplitVertically(true, before: false, profile: profile, targetSession: session, completion: { [weak self, weak windowController] pane, ok in
            MainActor.assumeIsolated {
                if pane == nil || !ok {
                    refusal.say()
                } else {
                    // A new pane takes the focus; the task was made to talk to its agent.
                    windowController?.tab(for: session)?.setActiveSessionPreservingMaximization(session)
                }
                self?.onChange?()
            }
        }, ready: { _, ok in
            MainActor.assumeIsolated { if !ok { refusal.say() } }
        })
    }
}

/// The app's one helper: started at launch, told about every session, stopped at quit.
extension iTermShellforgeSidebar {
    /// The daemon's package is copied to `Contents/Resources/daemon/shellforged`, alone in its folder:
    /// that folder is the daemon's PYTHONPATH, and iTerm2's own scripts sit at the top of Resources.
    static let link = DaemonLink(daemonDir: Bundle.main.resourceURL?.appendingPathComponent("daemon"),
                                 findPython: { PythonFinder.find(launcher: launcher).map(URL.init(fileURLWithPath:)) },
                                 reports: { allReports() },
                                 environment: { launcher.environment.variables })
    private static var tick: Timer?
    private static var rcCheck: Timer?
    /// The login shell's rc files, as last seen: a change reads the environment again (PRD E9).
    /// The shell and `ZDOTDIR` come from the environment Shellforge uses, read off the main thread.
    nonisolated(unsafe) private static var rcFiles = RCFiles(home: FileManager.default.homeDirectoryForCurrentUser,
                                                             environment: { launcher.environment.variables })

    /// One rc check at a time: `rcFiles` is touched only by the check in flight.
    private static var checkingRC = false

    /// Reads the environment again, off the main thread, when an rc file changed.
    private static func checkRCFiles() {
        guard !checkingRC else { return }
        checkingRC = true
        Task {
            defer { checkingRC = false }
            let reread = await BackgroundWork.run { () -> Bool in
                guard rcFiles.changed() else { return false }
                launcher.reload()
                return true
            }
            if reread { environmentChanged() }
        }
    }

    /// The Dock icon's badge: the rows waiting on you, once for the app, written only when it changes.
    private static let dockBadge = DockBadge.Setter { NSApp.dockTile.badgeLabel = $0 }
    static func updateDockBadge() {
        dockBadge.update(count: DockBadge.count(across: sidebars.allObjects))
    }

    /// Every window's sidebar re-reads whether the environment is a fallback.
    static func environmentChanged() {
        for model in sidebars.allObjects { model.environmentChanged() }
    }

    /// Starts the helper and the report tick; both stop at iTermApplicationWillTerminate.
    @objc static func startHelper() {
        // ModernTests run inside the app; a test run must not start, adopt or stop a real helper.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        link.start()
        machine.start()
        // A launch after a crash with lid sleep left off turns it back on first, then reads setup.
        Task { await backpack.launch() }
        // The footer says "Usage disconnected" from this check, so it runs at launch, not only when
        // the Agent hooks sheet is opened.
        Task { await hooks.refresh() }
        // jobPid and commandLine change with no notification; the tick reads them, and only a
        // changed list is sent.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                link.reportsMayHaveChanged()
                updateDockBadge()
            }
        }
        // Room for macOS to fire it with other wakeups: a job's change shows within 1.5 s.
        tick?.tolerance = 0.5
        // A tool installed and put on PATH in an rc file is found without a relaunch. The first
        // check only looks; it reads the environment, so it runs off the main thread too.
        checkRCFiles()
        // A command that missed read the environment again: every sidebar's warning follows.
        launcher.onReload = { DispatchQueue.main.async { MainActor.assumeIsolated { environmentChanged() } } }
        rcCheck = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { checkRCFiles() }
        }
        rcCheck?.tolerance = 5
        NotificationCenter.default.addObserver(forName: NSNotification.Name(iTermApplicationWillTerminate), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                tick?.invalidate()
                rcCheck?.invalidate()
                // Before anything else goes: the Mac must never be left unable to sleep.
                backpack.shutdown()
                machine.stop()
                link.shutdown()
            }
        }
    }

    /// Every session in every window, split panes included; the selected one of the selected tab
    /// is active.
    static func allReports() -> [SessionReport] {
        iTermController.sharedInstance().terminals().flatMap { window -> [SessionReport] in
            let current = window.currentSession()?.guid
            let windowId = window.terminalGuid ?? ""
            return window.tabs().enumerated().flatMap { index, tab in
                tab.sessions().map { session in
                    let scope = session.genericScope
                    return SessionReport.reading(sessionId: session.guid, windowId: windowId, tabIndex: index,
                                                active: session.guid == current) { scope.value(forVariableName: $0) }
                }
            }
        }
    }
}


/// View › Tunnels: Start or Stop per linked tunnel, kept current as the workspace and the tunnels'
/// states change. iTerm2's Open Quickly searches the main menu, so this is the palette's way in.
extension iTermShellforgeSidebar {
    private static let tunnelMenu = TunnelMenuController()

    /// Empty under ModernTests: building it reads the user's own workspace, which a test run must
    /// not touch, as `startHelper` does not start the helper there.
    @objc static func tunnelsMenu() -> NSMenu {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return NSMenu(title: "Tunnels") }
        return tunnelMenu.menu
    }

    /// The first window's sidebar: where a tunnel's start is checked and its keep-running read.
    /// The key window's sidebar, else the first: where a tunnel's start is checked and a problem said.
    fileprivate static var anySidebar: SidebarModel? { keySidebar ?? sidebars.allObjects.first }
}

@MainActor
private final class TunnelMenuController: NSObject, NSMenuItemValidation {
    let menu = NSMenu(title: "Tunnels")
    private var subscription: AnyCancellable?

    override init() {
        super.init()
        let document = iTermShellforgeSidebar.document, link = iTermShellforgeSidebar.link
        // Rebuilt only when the items change, never under an open menu for a token tally.
        subscription = TunnelMenu.items(projects: document.$workspace.map(\.projects).eraseToAnyPublisher(),
                                        stores: link.$store.eraseToAnyPublisher())
            .sink { [weak self] items in MainActor.assumeIsolated { self?.rebuild(items) } }
    }

    private func rebuild(_ items: [TunnelMenuItem]) {
        menu.removeAllItems()
        guard !items.isEmpty else {
            menu.addItem(NSMenuItem(title: TunnelMenu.emptyTitle, action: nil, keyEquivalent: ""))
            return
        }
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.alias
            menuItem.tag = item.starts ? 1 : 0
            menu.addItem(menuItem)
        }
    }

    /// Start or Stop by the tunnel's state now, not the one the item was built with: Open Quickly
    /// keeps the items it listed, and a tunnel can have changed since.
    @objc func choose(_ sender: NSMenuItem) {
        guard let alias = sender.representedObject as? String, let sidebar = iTermShellforgeSidebar.anySidebar else { return }
        if [.connecting, .up].contains(sidebar.tunnelState(alias)) { sidebar.stopTunnel(alias) } else { sidebar.startTunnel(alias) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        TunnelMenu.isEnabled(haveSidebar: iTermShellforgeSidebar.anySidebar != nil)
    }
}

/// A split's refusal, said at most once.
@MainActor
private final class SplitRefusal {
    private var said = false
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func say() {
        guard !said else { return }
        said = true
        action()
    }
}


/// The Tasks menu: Shellforge's keyboard commands, each acting on the key window's sidebar.
extension iTermShellforgeSidebar {
    /// Each window's sidebar, by its window controller.
    static let windows = SidebarWindows()
    private static let tasksController = TasksMenuController()

    @objc static func tasksMenu() -> NSMenu { tasksController.menu }

    /// The key window's sidebar: a panel of ours (a sheet) may be key, and its parent is meant.
    static var keySidebar: SidebarModel? {
        let window = NSApp.keyWindow.map { $0.sheetParent ?? $0 } ?? NSApp.mainWindow
        return windows.model(for: window?.windowController)
    }
}

@MainActor
private final class TasksMenuController: NSObject, NSMenuItemValidation {
    let menu = NSMenu(title: "Tasks")

    override init() {
        super.init()
        for item in SidebarCommandMenu.items {
            guard let command = item.command else { menu.addItem(.separator()); continue }
            let menuItem = NSMenuItem(title: item.title, action: #selector(performCommand(_:)), keyEquivalent: item.key)
            menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: item.modifiers.rawValue)
            menuItem.target = self
            menuItem.tag = command.rawValue
            menu.addItem(menuItem)
        }
    }

    @objc func performCommand(_ sender: NSMenuItem) {
        guard let command = SidebarCommand(rawValue: sender.tag) else { return }
        iTermShellforgeSidebar.keySidebar?.perform(command)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = SidebarCommand(rawValue: menuItem.tag), let sidebar = iTermShellforgeSidebar.keySidebar else { return false }
        return sidebar.can(command)
    }
}


/// The sidebar's width, as dragged, and whether new windows start with it hidden (⌃⌘S).
extension iTermShellforgeSidebar {
    /// Through iTerm2's own defaults domain, so a `-suite` run keeps its own sidebar.
    private static var layout: SidebarLayoutSettings { SidebarLayoutSettings(defaults: iTermUserDefaults.userDefaults()) }

    /// The preferred width a new window starts with: the last one dragged, in any window.
    @objc static func defaultPreferredWidth() -> CGFloat { layout.width }

    /// The width a window of `windowWidth` gives a sidebar that prefers `preferred`, with a
    /// toolbelt of `toolbeltWidth` showing on the right.
    @objc static func width(forPreferred preferred: CGFloat, windowWidth: CGFloat, toolbeltWidth: CGFloat) -> CGFloat {
        SidebarLayoutSettings.width(preferred, windowWidth: windowWidth, beside: toolbeltWidth)
    }

    /// The drag handle's frame for a sidebar of `frame`.
    @objc static func dragHandleFrame(forSidebar frame: NSRect) -> NSRect {
        let handle = SidebarLayoutSettings.dragHandle(edge: frame.maxX)
        return NSRect(x: handle.x, y: frame.minY, width: handle.width, height: frame.height)
    }

    /// View › Hide Sidebar, built from the same list as the Tasks menu's keys.
    @objc static func toggleSidebarItem(action: Selector, target: AnyObject) -> NSMenuItem {
        let item = SidebarCommandMenu.toggleSidebar
        let menuItem = NSMenuItem(title: item.title, action: action, keyEquivalent: item.key)
        menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: item.modifiers.rawValue)
        menuItem.target = target
        return menuItem
    }

    /// A window's preferred width after a drag of `delta`, saved to seed new windows.
    @objc static func dragged(_ preferred: CGFloat, by delta: CGFloat) -> CGFloat {
        let width = SidebarLayoutSettings.dragged(preferred, by: delta)
        layout.width = width
        return width
    }

    @objc static func startsHidden() -> Bool { layout.hidden }

    @objc static func setStartsHidden(_ hidden: Bool) { layout.hidden = hidden }
}
