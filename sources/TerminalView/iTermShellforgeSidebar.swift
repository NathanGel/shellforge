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
import ShellforgeDesign
import ShellforgeUI

@objc(iTermShellforgeSidebar)
@MainActor
final class iTermShellforgeSidebar: NSObject {

    /// One shared launcher, so the login shell's environment is read once per app run.
    nonisolated static let launcher = CommandLauncher()

    /// The Agent hooks sheet every window's sidebar opens: the hooks bundled in
    /// `Contents/Resources/hooks`, installed into the user's home only on a click.
    static let hooks: AgentHooksModel = {
        let model = AgentHooksModel(integrations: HookIntegrations(support: support, resources: .bundled(resourceURL: Bundle.main.resourceURL)),
                                    names: Dictionary(uniqueKeysWithValues: AgentPresets.all.map { ($0.id, $0.name) }))
        // A dev build asks before installing over the installed app's hooks.
        model.prompter = WarningPrompter()
        return model
    }()

    /// The Mac's cpu, ram and battery for every window's footer, sampled every five seconds while
    /// the helper runs and some window's sidebar can be seen (`refreshShownSidebars`).
    static let machine = MachineMonitor(sensor: LiveMachineSensor(), power: IOKitPowerSource())

    /// AiTerm's Backpack Mode, one for the app: lid sleep through the sudoers rule the Mac card's
    /// Allow… installs, the iPhone's hotspot through CoreWLAN. Its toasts go to every sidebar's banner.
    static let backpack = BackpackController(
        ports: BackpackPorts.live(),
        // The app's own suite; the bundle-id domain only for an earlier version's crash marker.
        settings: BackpackSettings(defaults: iTermUserDefaults.userDefaults(), legacy: UserDefaults.standard, secrets: Keychain.shared),
        agentsWorking: { link.store.sessions.values.contains { $0.state == .working } },
        openLocationSettings: {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
        },
        toast: { message in for model in sidebars.allObjects { model.lastError = message } })

    /// Before anything reads them: the settings earlier versions kept in the bundle-id domain are
    /// copied into the app's own suite, once (`SettingsMigration`).
    @objc static func moveSettingsIntoSuite() {
        SettingsMigration.run(from: UserDefaults.standard, into: iTermUserDefaults.userDefaults())
    }

    /// Reads Shellforge's one Keychain item now, off the main thread, so its one prompt after an
    /// update comes at launch rather than when Buddy or AI first needs a secret.
    @objc nonisolated static func warmKeychain() {
        DispatchQueue.global(qos: .userInitiated).async { Keychain.shared.warm() }
    }

    /// Every window's sidebar model, for Backpack's toasts.
    private static let sidebars = NSHashTable<SidebarModel>.weakObjects()
    /// Each model's sidebar view, to ask whether it can be seen. Weak both ways: the window owns both.
    private static let sidebarViews = NSMapTable<SidebarModel, NSView>.weakToWeakObjects()
    /// How each window's sidebar opens the Backpack sheet, for ⌘B.
    private static let backpackSheets = WindowSheets()
    /// How each window's sidebar opens the feedback sheet, for Help › Send Feedback….
    static let feedbackSheets = WindowSheets()

    /// The key window's terminal, and only that: a panel of ours (the sheet, Mac Settings) may be key, and its parent is meant.
    /// Nil when a window that is no terminal (Settings, Open Quickly) is key.
    static var keyWindowTerminal: PseudoTerminal? {
        let window = NSApp.keyWindow.map { $0.sheetParent ?? $0 } ?? NSApp.mainWindow
        return window?.windowController as? PseudoTerminal
    }

    /// The key window's terminal, else the current one: for the commands that may reach a background window.
    static var keyTerminal: PseudoTerminal? { keyWindowTerminal ?? iTermController.sharedInstance()?.currentTerminal }

    /// The View menu's Backpack Mode (⌘B): AiTerm's toggle, the sheet on the key window's sidebar.
    @objc static func toggleBackpack(_ sender: Any?) {
        let terminal = keyTerminal
        BackpackToggle(backpack: backpack, presentSheet: { backpackSheets.present(for: terminal) }).run()
    }

    /// The menu item's checkmark.
    @objc static func backpackIsOn() -> Bool { backpack.isOn }

    /// Every agent's model list, read from the user's own home.
    nonisolated static let catalogue = ModelCatalogue(home: FileManager.default.homeDirectoryForCurrentUser, launcher: launcher)

    /// The app's one feedback prompt: every window's banner and Settings switch share it. A Development build never shows the banner.
    /// It checks again when Shellforge comes to the front and when the Mac wakes, so someone who keeps
    /// one window open for weeks still sees it once it is due.
    static let feedback: FeedbackPrompt = {
        let prompt = FeedbackPrompt(defaults: iTermUserDefaults.userDefaults(),
                                    channel: BuildChannel(infoDictionary: Bundle.main.infoDictionary))
        prompt.refresh(on: [NSApplication.didBecomeActiveNotification], from: .default)
        prompt.refresh(on: [NSWorkspace.didWakeNotification], from: NSWorkspace.shared.notificationCenter)
        return prompt
    }()

    /// The running app's Application Support folder, as iTerm2 names it: the executable's name, or the
    /// `-suite` a dev build runs with. The workspace and the agents live here, so a dev build never
    /// reads or writes the installed app's.
    static let dataFolder = URL(fileURLWithPath: FileManager.default.applicationSupportDirectory(), isDirectory: true)

    /// The helper's folder, socket and hook port, and what the status-line shims read: the data
    /// folder's, so a dev build has a helper of its own. The installed app's data folder is
    /// `Application Support/Shellforge`, which keeps port 47831. Configured on first use, at launch.
    static let support: ShellforgeSupport = {
        let support = ShellforgeSupport(folder: dataFolder)
        ShellforgePaths.configure(support)
        return support
    }()

    /// The one workspace every window's sidebar shows and changes.
    static let document = WorkspaceDocument(store: WorkspaceStore(folder: dataFolder))

    /// The activity bar's order: one for the app, so every window's bar follows a drag in any of
    /// them; saved on this Mac only (a `NoSync` default). Each window keeps its own selected panel.
    static let activityOrder = ActivityOrderSource(defaults: iTermUserDefaults.userDefaults())

    /// The Files panel's model: one for the app, so every window draws the same trees and open
    /// folders from one set of watchers. Made the first time the panel shows in any window; until
    /// then nothing is listed or watched. Each window opens files in its own tabs.
    private static let files: FilesHolder = {
        let holder = FilesHolder { makeFiles() }
        // A window's panel appeared: whether its sidebar can be seen is checked now.
        holder.onRegister = { refreshPanelVisibility() }
        return holder
    }()

    /// The Git panel's model: one for the app, so every window draws the same repositories from one
    /// set of watchers. Made the first time the panel shows in any window; until then no repository
    /// is read or watched. Each window opens diffs in its own tabs and asks its own questions.
    private static let git: GitHolder = {
        let holder = GitHolder { makeGit() }
        holder.onRegister = { refreshPanelVisibility() }
        return holder
    }()

    /// What the app bundle gives the agents: `shellforge-status`, `shellforge-run` and the ready-made agents.
    static let agentTools = AgentTools.bundled(resourceURL: Bundle.main.resourceURL, bundlePath: Bundle.main.bundlePath,
                                               dataFolder: dataFolder)

    /// The agents as last read, for the helper's reports: which custom agent a tab runs.
    private(set) static var agents: [AgentDefinition] = AgentPresets.all

    /// The agents in the agents folder, the ready-made ones and the presets, read now.
    private static func loadAgents() -> (agents: [AgentDefinition], problem: String?, readyMade: Set<String>) {
        let loaded = AgentFiles.load(AgentRegistry(folder: agentTools.agentsFolder, readyMade: agentTools.readyMade))
        agents = loaded.agents
        return loaded
    }

    /// Settings › Agents added, changed or removed an agent: every window's New Task, and the
    /// helper's reports, use the agents as they are now.
    static func agentsChanged() {
        DLog("Shellforge: agents changed; reloading them for every window")
        let loaded = loadAgents()
        for model in sidebars.allObjects {
            model.reloadAgents(loaded.agents, readyMade: loaded.readyMade)
            if let problem = loaded.problem { model.lastError = problem }
        }
        link.reportsMayHaveChanged()
    }

    /// A new sidebar for `windowController`'s window.
    @objc static func makeView(for windowController: PseudoTerminal) -> NSView {
        let host = iTermShellforgeHost(windowController: windowController)
        // Read for each new window: an agent file added since shows in that window's New Task.
        let loaded = loadAgents()
        let model = SidebarModel(host: host, document: document, launcher: launcher, feed: link,
                                 agents: loaded.agents, catalogue: { try catalogue.models(for: $0) },
                                 jiraSettings: { JiraSettings.load(store: Keychain.shared, defaults: iTermUserDefaults.userDefaults()) },
                                 gitLabSettings: { GitLabSettings.load(store: Keychain.shared, defaults: iTermUserDefaults.userDefaults()) },
                                 gitHubSettings: { GitHubSettings.load(store: Keychain.shared) },
                                 modelDefaults: { ModelSettings.loadAll(for: $0, defaults: iTermUserDefaults.userDefaults()) },
                                 sshConfig: .user,
                                 readyMade: loaded.readyMade, secrets: Keychain.shared, tools: agentTools)
        if let problem = loaded.problem { model.lastError = problem }
        model.prompter = WarningPrompter()
        windows.add(model, for: windowController)
        model.onEnvironmentReloaded = { environmentChanged() }
        sidebars.add(model)
        // A window opened after the schedule came due shows the note at once.
        feedback.refresh()
        watchClicks()
        let view = ShellforgeSidebar.makeView(model: model, chooseFolder: FolderChooser.choose, hooks: hooks, machine: machine,
                                          backpack: backpack, zoom: zoom, terminalMatch: iTermShellforgeTerminalMatch.settings, theme: iTermShellforgeThemes.settings,
                                          appDefaults: iTermUserDefaults.userDefaults(),
                                          feedback: feedback, activityOrder: activityOrder, files: files, git: git,
                                          panelCornerRadius: floats ? panelCornerRadius : nil,
                                          agentTools: agentTools, agentsChanged: { agentsChanged() },
                                          showBackpack: { [weak windowController] present in
            if let windowController { backpackSheets.register(windowController, present) }
        }, showFeedback: { [weak windowController] present in
            if let windowController { feedbackSheets.register(windowController, present) }
        }, hideSidebar: { [weak windowController] in
            (windowController?.contentView as? iTermRootTerminalView)?.toggleShellforgeSidebar()
        })
        sidebarViews.setObject(view, forKey: model)
        return view
    }

    /// The app's Files panel model: the workspace's projects, followed as they are added, removed
    /// or reordered; its open folders saved on this Mac, in the app's own suite.
    private static func makeFiles() -> FilesModel {
        let files = FilesModel(projects: [], launcher: launcher, defaults: iTermUserDefaults.userDefaults(),
                               watcher: { _ in FolderWatcher() })
        // The publisher hands over the current projects at once, then each change.
        files.follow(document.$workspace.map(\.projects))
        return files
    }

    /// The app's Git panel model: the workspace's projects and their tasks' worktrees, followed as
    /// they change. Its watchers pass on only the changes that can move what git reports.
    private static func makeGit() -> GitModel {
        let git = GitModel(projects: [], tasks: [], launcher: launcher,
                           watcher: { _ in FolderWatcher(filter: { GitWatchPaths.isRelevant($0, root: $1) }) })
        // The publisher hands over the current workspace at once, then each change.
        git.follow(document.$workspace)
        return git
    }

    /// The default profile changed to run the login shell in `directory`.
    /// `initialText` is typed into the shell once it starts — the task's agent — already escaped for
    /// iTerm2's interpolated-string evaluator (`TabCommand.initialText`).
    /// A profile key PTYSession reads: its initial text is sent once, then cleared from the
    /// session, so a split or a new tab copying the session's profile does not run the agent again.
    @objc nonisolated static let initialTextOnceKey = "Shellforge Initial Text Once"  // Localization unneeded

    nonisolated static func taskTabProfile(base: [AnyHashable: Any], directory: String, initialText: String? = nil) -> [AnyHashable: Any] {
        var profile = base
        if let initialText {
            profile[KEY_INITIAL_TEXT] = initialText
            profile[initialTextOnceKey] = true
        }
        profile[KEY_CUSTOM_COMMAND] = "No"  // Localization unneeded
        profile[KEY_CUSTOM_DIRECTORY] = kProfilePreferenceInitialDirectoryCustomValue
        profile[KEY_WORKING_DIRECTORY] = directory
        return profile
    }

    /// The default profile changed to run `argv` itself in `directory`, as its custom command: no
    /// login shell is started to type into, and no initial text is sent. `title` is the tab's name.
    nonisolated static func fileTabProfile(base: [AnyHashable: Any], directory: String, argv: [String], title: String) -> [AnyHashable: Any] {
        var profile = taskTabProfile(base: base, directory: directory, initialText: nil)
        profile[KEY_CUSTOM_COMMAND] = kProfilePreferenceCommandTypeCustomValue
        profile[KEY_COMMAND_LINE] = commandLine(argv)
        profile[KEY_RUN_COMMAND_IN_LOGIN_SHELL] = false
        profile[KEY_INITIAL_TEXT] = ""
        profile[KEY_NAME] = literalName(title)
        return profile
    }

    /// `argv` as a profile's command line that iTerm2 reads back as exactly these words, whatever
    /// they hold. The line is first evaluated as an interpolated string, where `\\` is one backslash
    /// and `\(` would start an expression, so every backslash is doubled. Then `$$NAME$$` is a
    /// parameter iTerm2 asks for, so no two `$` are ever adjacent: a quote closed and reopened
    /// (`$""$`) sits between them. Then `componentsInShellCommand` splits it: each word is double-
    /// quoted, where only `\\` and `\"` are escapes, and quoted, it is never split or `~`-expanded.
    nonisolated static func commandLine(_ argv: [String]) -> String {
        argv.map { word -> String in
            // Scalar by scalar: a quote followed by a combining mark is one Character, and still a quote.
            var quoted = "\""
            var previous: Unicode.Scalar?
            for scalar in word.unicodeScalars {
                if scalar == "$", previous == "$" { quoted += "\"\"" }
                switch scalar {
                case "\\": quoted += "\\\\"
                case "\"": quoted += "\\\""
                default: quoted.unicodeScalars.append(scalar)
                }
                previous = scalar
            }
            return quoted + "\""
        }.joined(separator: " ").replacingOccurrences(of: "\\", with: "\\\\")
    }

    /// `name` as a profile's name that shows as it is: iTerm2 reads `$$NAME$$` in it as a parameter
    /// to ask for, and `$$$$` as `$$`.
    nonisolated static func literalName(_ name: String) -> String {
        name.replacingOccurrences(of: "$$", with: "$$$$")
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
            // Another pane of a split tab focused: the tab's row is named by its focused pane.
            .init(kCurrentSessionDidChange),
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
    /// One for the app: every window's host signals it, and one list is read and sent. At most four
    /// a second: Claude's spinner retitles its tab several times a second, every retitle changes
    /// the list, and each list sent makes the helper run a tick. A tab opened or closed waits a
    /// quarter of a second at most, well inside the two seconds a hook waits for the next list.
    private static let reports = ChangeCoalescer(schedule: ChangeCoalescer.after(0.25)) {
        iTermShellforgeSidebar.link.reportsMayHaveChanged()
    }

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
                               terminalId: terminal, paneCount: panes.count, panel: Self.panel(ofPanes: panes))
        }
    }

    /// Tags a session with the panel that opened it; iTerm2 restores the tag with the session.
    static func tag(_ session: PTYSession, panel: PanelTab) {
        session.genericScope.setValue(panel.tagValue, forVariableNamed: ShellforgeTags.panel)
    }

    /// A tab's panel, from its panes' tags with the focused pane first.
    static func panel(ofPanes panes: [PTYSession]) -> PanelTab? {
        TabSnapshot.panel(ofPanes: panes.map { $0.genericScope.value(forVariableName: ShellforgeTags.panel) as? String })
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
                let closed = TaskTabs.closeOne(tab, in: window, tabs: { $0.tabs() }, keep: Self.freshTab,
                                               select: { _, tab in tab.tabViewItem?.tabView?.selectTabViewItem(tab.tabViewItem) },
                                               close: { window, tab in _ = window.closeTabIfConfirmed(tab) },
                                               discard: { window, tab in window.close(tab) })
                onChange?()
                return closed
            }
        }
        return false
    }

    /// iTerm2 closes a window with its last tab, and the sidebar with it: the window gets iTerm2's
    /// own new tab first — the default profile in its default folder, never the folder of a tab
    /// about to close (a worktree being deleted). Added at once, before any close runs.
    static func keepOpen(_ window: PseudoTerminal) -> Bool { freshTab(window) != nil }

    /// iTerm2's own new tab in `window`, as `keepOpen` adds it; nil when it could not be added.
    static func freshTab(_ window: PseudoTerminal) -> PTYTab? {
        guard let profile = ProfileModel.sharedInstance()?.defaultBookmark(),
              let session = window.createTab(withProfile: profile, withCommand: nil, environment: nil, tabIndex: nil,
                                             previousDirectory: nil, parent: nil, completion: nil) else { return nil }
        return window.tab(for: session)
    }

    /// Every window's panes of the task: tagged with it, or untagged in a tab that holds one tagged —
    /// a pane just split off (⌘D) before `joinPanes` gives it the tag.
    func paneCount(ofTask id: UUID) -> Int {
        let tag = id.uuidString.lowercased()
        let windows = (iTermController.sharedInstance()?.terminals() ?? []) as [PseudoTerminal]
        return windows.flatMap { $0.tabs() }.reduce(0) { count, tab in
            let sessions: [PTYSession] = tab.sessions()
            return count + TaskTabs.paneCount(of: tag, in: sessions.map { $0.genericScope.value(forVariableName: ShellforgeTags.task) as? String })
        }
    }

    /// The pane of session `id` — the one focused when Close was chosen, not whichever is focused
    /// by the time a Remove's checks are done — closed as iTerm2's Close closes it: a running job
    /// asks first. An unsplit tab closes as Close Tab does.
    @discardableResult
    func closePane(ofTab id: String) -> Bool {
        let windows = (iTermController.sharedInstance()?.terminals() ?? []) as [PseudoTerminal]
        for window in windows {
            for tab in window.tabs() where tab.sessions().contains(where: { $0.guid == id }) {
                guard tab.sessions().count > 1, let pane = tab.sessions().first(where: { $0.guid == id }) else { return close(tab: id) }
                let closed = window.closeSession(withConfirmation: pane)
                onChange?()
                return closed
            }
        }
        return false
    }

    /// A pane split off a task's, a terminal's or a panel's tab (⌘D) carries no tag: it takes its
    /// tab's, so the tab stays the task's, or the panel's, whichever pane closes first.
    func joinPanes() {
        for tab in windowController?.tabs() ?? [] {
            Self.join(tab.sessions())
        }
    }

    /// One tab's panes: each untagged one takes the tag its tabmates carry, name by name.
    static func join(_ sessions: [PTYSession]) {
        for name in [ShellforgeTags.task, ShellforgeTags.project, ShellforgeTags.terminal, ShellforgeTags.panel] {
            let tags = sessions.map { $0.genericScope.value(forVariableName: name) as? String }
            guard let tag = TaskTabs.joining(tags) else { continue }
            for (session, existing) in zip(sessions, tags) where existing == nil {
                session.genericScope.setValue(tag, forVariableNamed: name)
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

    /// A login shell of no task and no project in `directory`, selected: it lists under Other Tabs.
    func openPlainTab(in directory: String) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        let profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory, initialText: nil)
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: nil, completion: { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        })
    }

    /// A tab of no task — a tunnel answered in a tab, or one a panel opened, tagged with `panel` —
    /// running `command` in `directory`.
    func openTab(in directory: String, title: String, command: String, panel: PanelTab?) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        var profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory,
                                                            initialText: TabCommand.initialText(command))
        profile[KEY_NAME] = title
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: { session in
            if let panel { Self.tag(session, panel: panel) }
        }, completion: { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        })
    }

    /// A tab a panel opened on a file — its editor, its diff — tagged with `panel`, whose own command
    /// is `command` run by the account's login shell: the file's path is an argument, never typed.
    func openTab(in directory: String, title: String, running command: FileCommand, panel: PanelTab) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        let argv = command.argv(shell: iTermOpenDirectory.userShell() ?? "/bin/zsh")
        DLog("Shellforge: opening a file tab running \(argv)")
        let profile = iTermShellforgeSidebar.fileTabProfile(base: base, directory: directory, argv: argv, title: title)
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: { session in
            Self.tag(session, panel: panel)
        }, completion: { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        })
    }

    /// The tunnels' ports are exported before the command, in the line typed into the shell: an
    /// iTerm2 profile has no environment of its own to carry them.
    /// `beside`, when given, runs in a pane split off to the right of the agent's, in the same folder.
    /// `launch`'s environment, secrets included, is armed for the new session before its shell starts
    /// and types `command`, for the `shellforge-run` at the head of it to take.
    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String, command: String?, environment: [String: String],
                 beside: String?, launch: AgentLaunch?) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        let profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory,
                                                            initialText: TabCommand.exporting(environment, then: command).map(TabCommand.initialText))
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: { session in
            session.genericScope.setValue(taskId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.task)
            session.genericScope.setValue(projectId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.project)
            // Only a launch through shellforge-run takes anything from the helper.
            if let launch, launch.needsArming {
                DLog("Shellforge: arming a launch for a new task tab")
                let guid: String = session.guid
                MainActor.assumeIsolated {
                    iTermShellforgeSidebar.link.armLaunch(session: guid, agentId: launch.agentId, environment: launch.environment)
                }
            }
        }, completion: { [weak self, weak windowController] session, ok in
            MainActor.assumeIsolated {
                self?.onChange?()
                // A new task or review is a natural pause, with the sidebar in view.
                if ok { iTermShellforgeSidebar.feedback.refresh() }
                // An agent that takes its prompt typed in gets it once it has settled; armed above.
                if ok, let launch {
                    iTermShellforgeSignals.type(launch, into: session) { [weak windowController] in
                        iTermShellforgeSidebar.windows.model(for: windowController)?.typedPromptAbandoned(agentId: launch.agentId, title: title)
                    }
                }
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
    static let link = DaemonLink(support: support, daemonDir: Bundle.main.resourceURL?.appendingPathComponent("daemon"),
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

    /// Removes the agent-session markers Shellforge inherited from whoever started it, before any
    /// window is restored or shell started: every tab, and every login-shell read, starts from this
    /// process's environment (InheritedEnvironment). Then drops any support folder inherited from
    /// another copy (a dev build's terminal) and, in a dev build, sets its own, so an agent in any of
    /// its tabs — iTerm2's own New Tab included — reports to its helper
    /// (`ShellforgeSupport.sessionEnvironment`). The installed app's tabs carry no new variable.
    @objc static func scrubInheritedEnvironment() {
        for name in InheritedEnvironment.agentMarkers(in: ProcessInfo.processInfo.environment) { unsetenv(name) }
        unsetenv(ShellforgeSupport.environmentVariable)
        for (name, value) in support.sessionEnvironment { setenv(name, value, 1) }
    }

    /// Starts the helper and the report tick; both stop at iTermApplicationWillTerminate.
    @objc static func startHelper() {
        // ModernTests run inside the app; a test run must not start, adopt or stop a real helper.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // shellforge-status and shellforge-run find the hook server by this file; a custom agent may
        // need it before any built-in's hooks are installed, which also record it. Off the main thread.
        let support = support
        DispatchQueue.global(qos: .utility).async {
            do {
                try ShimPort.record(support.hookPort, in: support)
            } catch {
                DLog("Shellforge: couldn’t record the hook port")
            }
        }
        link.start()
        machine.start()
        // A launch after a crash with lid sleep left off turns it back on first, then reads setup.
        Task { await backpack.launch() }
        // The footer says "Usage disconnected" from this check, so it runs at launch, not only when
        // the Agent hooks sheet is opened.
        Task { await hooks.refresh() }
        // jobPid and commandLine change with no notification; the tick reads them, and only a
        // changed list is sent. In the common modes, so it keeps firing while a menu is open or a
        // window is dragged or resized.
        let reportTick = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                link.reportsMayHaveChanged()
                updateDockBadge()
                refreshShownSidebars()
            }
        }
        RunLoop.main.add(reportTick, forMode: .common)
        tick = reportTick
        // A window uncovered, brought back from the Dock or the app brought forward: its badges and
        // the Mac's readings are read now, not on the next tick.
        let shownMayHaveChanged: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                                        NSWindow.didDeminiaturizeNotification,
                                                        NSApplication.didBecomeActiveNotification]
        for name in shownMayHaveChanged {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refreshShownSidebars() }
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

    /// Each task's +n −m in every sidebar that can be seen — none for a window hidden, in the Dock or
    /// covered — and the Mac's readings only while one can. DiffStats keeps an answer 5 s, 30 s
    /// while the app is in the background, so this costs git that often at most.
    private static func refreshShownSidebars() {
        let background = !NSApp.isActive
        var anyShown = false
        for model in sidebars.allObjects {
            guard let view = sidebarViews.object(forKey: model), SidebarVisibility.isShowing(view) else { continue }
            anyShown = true
            Task { await model.refreshDiffs(background: background) }
        }
        if anyShown == machine.paused {
            DLog("Shellforge: a sidebar shows: \(anyShown); the Mac's readings \(anyShown ? "resume" : "pause")")
        }
        machine.setShown(anyShown)
        refreshPanelVisibility()
    }

    /// The Files and Git panels watch and read only while a sidebar that can be seen — not hidden
    /// (⌃⌘S), not in the Dock, not covered — has them selected; otherwise a change only marks what
    /// to read when one shows them again.
    private static func refreshPanelVisibility() {
        let shown = ShellforgeSidebar.visiblePanels(sidebars.allObjects.compactMap { model in
            sidebarViews.object(forKey: model).map { view in (SidebarVisibility.isShowing(view), ShellforgeSidebar.shownPanel(of: view)) }
        })
        files.setVisible(shown.contains(.files))
        git.setVisible(shown.contains(.git))
    }

    /// Every session in every window, split panes included; the selected one of the selected tab
    /// is active.
    static func allReports() -> [SessionReport] {
        // Each task's agent, by task: a task's tab reports it while its program, or shellforge-run
        // starting it, is in the foreground (`AgentIdentity.customAgent`).
        let taskAgents = Dictionary(document.workspace.tasks.map { ($0.id, $0.agent) }, uniquingKeysWith: { first, _ in first })
        return iTermController.sharedInstance().terminals().flatMap { window -> [SessionReport] in
            let current = window.currentSession()?.guid
            let windowId = window.terminalGuid ?? ""
            return window.tabs().enumerated().flatMap { index, tab in
                tab.sessions().map { session in
                    let scope = session.genericScope
                    return SessionReport.reading(sessionId: session.guid, windowId: windowId, tabIndex: index,
                                                active: session.guid == current, value: { scope.value(forVariableName: $0) },
                                                taskAgent: { taskAgents[$0] ?? nil }, agents: agents,
                                                signals: { iTermShellforgeSignals.signals($0) })
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
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return NSMenu(title: tunnelsMenuTitle) }
        return tunnelMenu.menu
    }

    /// The first window's sidebar: where a tunnel's start is checked and its keep-running read.
    /// The key window's sidebar, else the first: where a tunnel's start is checked and a problem said.
    fileprivate static var anySidebar: SidebarModel? { keySidebar ?? sidebars.allObjects.first }

    /// The Tunnels menu's title.
    fileprivate static var tunnelsMenuTitle: String {
        String(localized: "Shellforge.TunnelsMenu",
               defaultValue: "Tunnels",
               comment: "Title of the menu that lists the SSH tunnels Shellforge can start and stop")
    }
}

@MainActor
private final class TunnelMenuController: NSObject, NSMenuItemValidation {
    let menu = NSMenu(title: iTermShellforgeSidebar.tunnelsMenuTitle)
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
        windows.model(for: keyWindowTerminal)
    }

    private static let panelsController = PanelMenuController()

    /// View › Show Sessions, Show Metrics, Show Files and Show Git, for the key window's sidebar.
    @objc static func panelMenuItems() -> [NSMenuItem] { panelsController.items }

    /// The key window's sidebar view, as `makeView` made it.
    static var keySidebarView: NSView? { keySidebar.flatMap { sidebarViews.object(forKey: $0) } }

    /// Shows `panel` in the key window's sidebar, revealing the sidebar first if it is hidden.
    static func show(_ panel: ActivityPanel) {
        guard let view = keySidebarView else { return }
        if let root = keyWindowTerminal?.contentView as? iTermRootTerminalView, root.shellforgeSidebarHidden {
            root.toggleShellforgeSidebar()
        }
        ShellforgeSidebar.show(panel, on: view)
    }
}

/// View › Show Sessions, Show Metrics, Show Files, Show Git and Show SSH: each item's tag is its panel's place in `ActivityPanel.allCases`.
/// A panel the activity bar hides has its item hidden and disabled, so its key does nothing.
@MainActor
private final class PanelMenuController: NSObject, NSMenuItemValidation {
    private(set) var items: [NSMenuItem] = []
    private var watch: AnyCancellable?

    override init() {
        super.init()
        items = SidebarCommandMenu.panels.map { item in
            let menuItem = NSMenuItem(title: item.title, action: #selector(showPanel(_:)), keyEquivalent: item.key)
            menuItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: item.modifiers.rawValue)
            menuItem.target = self
            menuItem.tag = ActivityPanel.allCases.firstIndex(of: item.panel) ?? 0
            return menuItem
        }
        watch = iTermShellforgeSidebar.activityOrder.$hidden.sink { [weak self] hidden in
            self?.showOnly(SidebarCommandMenu.panels(hidden: hidden).map(\.panel))
        }
    }

    private func showOnly(_ shown: [ActivityPanel]) {
        for item in items { item.isHidden = Self.panel(of: item).map { !shown.contains($0) } ?? true }
    }

    private static func panel(of item: NSMenuItem) -> ActivityPanel? {
        ActivityPanel.allCases.indices.contains(item.tag) ? ActivityPanel.allCases[item.tag] : nil
    }

    @objc func showPanel(_ sender: NSMenuItem) {
        guard let panel = Self.panel(of: sender) else { return }
        iTermShellforgeSidebar.show(panel)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let panel = Self.panel(of: menuItem), !iTermShellforgeSidebar.activityOrder.hidden.contains(panel),
              let view = iTermShellforgeSidebar.keySidebarView else { return false }
        menuItem.state = ShellforgeSidebar.shownPanel(of: view) == panel ? .on : .off
        return true
    }
}

@MainActor
private final class TasksMenuController: NSObject, NSMenuItemValidation {
    let menu = NSMenu(title: String(localized: "Shellforge.TasksMenu",
                                    defaultValue: "Tasks",
                                    comment: "Title of the menu of Shellforge’s task commands (New Task, New Review and the like)"))

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


/// ⌘+ / ⌘− / ⌘0 on the sidebar: the View menu's Make Text Bigger, Smaller and Normal Size zoom the
/// sidebar instead of the terminal while the window's last click was in the sidebar.
extension iTermShellforgeSidebar {
    /// The app's one sidebar text size, every window's.
    static let zoom = SidebarZoom(settings: layout)
    /// The size as a factor of normal, for tests that cannot import ShellforgeUI.
    static var textScaleFactor: CGFloat { zoom.scale.factor }
    /// Back to normal size, for those tests' tear-down.
    static func resetTextScale() { zoom.reset() }
    private static let clicks = SidebarClicks()
    private static var clickMonitor: Any?

    /// Notes which side of a terminal window each mouse-down lands on. Installed with the first
    /// sidebar; it lets every event through.
    static func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated {
                if let window = event.window, window.windowController is PseudoTerminal {
                    clicks.clicked(in: window, on: window.contentView?.superview?.hitTest(event.locationInWindow))
                }
            }
            return event
        }
    }

    /// Steps the sidebar's text size when `terminal`'s sidebar shows and was clicked last: up for a
    /// positive `step`, down for a negative one, back to normal for 0. NO leaves the key to the terminal.
    @objc static func zoomSidebar(in terminal: PseudoTerminal, by step: Int) -> Bool {
        guard let root = terminal.contentView, root.hasShellforgeSidebar, !root.shellforgeSidebarHidden,
              clicks.sidebarIsActive(in: terminal.window) else {
            return false
        }
        switch step {
        case 0: zoom.reset()
        case 1...: zoom.bigger()
        default: zoom.smaller()
        }
        return true
    }
}

/// The sidebar's width, as dragged, and whether new windows start with it hidden (⌃⌘S).
extension iTermShellforgeSidebar {
    /// Through iTerm2's own defaults domain, so a `-suite` run keeps its own sidebar.
    private static var layout: SidebarLayoutSettings { SidebarLayoutSettings(defaults: iTermUserDefaults.userDefaults()) }

    /// The preferred width a new window starts with: the last one dragged, in any window.
    @objc static func defaultPreferredWidth() -> CGFloat { layout.width }

    /// The sidebar floats as a rounded panel inside the window on macOS 26 and later.
    @objc static var floats: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 }

    /// Whether a window of `type` is one the floating sidebar reshapes: a normal, maximized or
    /// centred window on macOS 26. Hotkey, edge-anchored, untitled and accessory windows keep
    /// iTerm2's own rules.
    @objc static func floatsWindow(ofType type: iTermWindowType) -> Bool {
        floats && (type == .WINDOW_TYPE_NORMAL || type == .WINDOW_TYPE_MAXIMIZED || type == .WINDOW_TYPE_CENTERED)
    }

    /// The band an empty unified toolbar gives a window's title bar on macOS 26, which the window
    /// buttons are centred in: the title strip beside a floating sidebar is as tall.
    @objc static var titlebarBandHeight: CGFloat { 52 }

    /// Whether a window of `type`, entered from `savedType`, floats its sidebar: as `floatsWindow(ofType:)`,
    /// and a Lion full-screen window entered from one that floats.
    @objc static func floatsWindow(ofType type: iTermWindowType, savedType: iTermWindowType) -> Bool {
        floatsWindow(ofType: type) ||
            ((type == .WINDOW_TYPE_LION_FULL_SCREEN || type == .WINDOW_TYPE_TRADITIONAL_FULL_SCREEN) && floatsWindow(ofType: savedType))
    }

    /// Whether a window carries the toolbar's band: a floating one, outside full screen.
    @objc static func wantsTitlebarBand(windowType: iTermWindowType, savedType: iTermWindowType, fullScreen: Bool) -> Bool {
        floatsWindow(ofType: windowType, savedType: savedType) && !fullScreen
    }

    /// How far the floating panel stands off the window's edges.
    @objc static var floatingInset: CGFloat { Space.inset }

    /// The panel's corners, concentric with the window's.
    static var panelCornerRadius: CGFloat { panelCornerRadius(forWindowRadius: iTermWindowCornerRadiusDetector.fallbackCornerRadius) }

    /// The panel's corner radius in a window whose own is `windowRadius`: concentric with it.
    /// A square window — full screen — has no corner to follow: the panel keeps the rounding it has
    /// in a window.
    /// A measurement below a plain window's radius is a mismeasure — a toolbar window is never less
    /// round — and the panel never goes square: at least the rounding it had at an 8 pt inset.
    static func panelCornerRadius(forWindowRadius windowRadius: CGFloat) -> CGFloat {
        let radius = max(windowRadius, iTermWindowCornerRadiusDetector.fallbackCornerRadius)
        return max(Radius.group, radius - floatingInset)
    }

    /// Tells the floating `sidebar` its window's corner radius as now measured, so the panel's
    /// corners stay concentric with the window's — a toolbar rounds them further on macOS 26.
    @objc static func updatePanelCornerRadius(in sidebar: NSView, windowRadius: CGFloat) {
        guard floats else { return }
        ShellforgeSidebar.setPanelCornerRadius(panelCornerRadius(forWindowRadius: windowRadius), on: sidebar)
    }

    /// What the sidebar last heard as its panel's radius, for host tests.
    static func reportedPanelCornerRadius(of sidebar: NSView) -> CGFloat? { ShellforgeSidebar.panelCornerRadius(of: sidebar) }

    /// The width a window of `windowWidth` gives a sidebar that prefers `preferred`, with a
    /// toolbelt of `toolbeltWidth` showing on the right.
    @objc static func width(forPreferred preferred: CGFloat, windowWidth: CGFloat, toolbeltWidth: CGFloat) -> CGFloat {
        SidebarLayoutSettings.width(preferred, windowWidth: windowWidth, beside: toolbeltWidth)
    }

    /// The narrowest a window showing the sidebar can be dragged, with a toolbelt of `toolbeltWidth`.
    /// The toolbelt as iTerm2 will lay it out: at most half the window.
    @objc static func minimumWindowWidth(toolbeltWidth: CGFloat) -> CGFloat {
        SidebarLayoutSettings.minimumWindowWidth(beside: toolbeltWidth, toolbeltMaxFraction: 0.5)
    }

    /// Tells the floating `sidebar` where the window's buttons sit inside it, so its header shares
    /// their row; nil while they are not inside it — hidden in a compact window or full screen, or
    /// not over the sidebar at all.
    /// The window's buttons are its own again — a window that does not float, a compact one say —
    /// so the header keeps its own toggle.
    @objc static func clearWindowControls(in sidebar: NSView) {
        ShellforgeSidebar.setWindowControls(nil, on: sidebar)
    }

    /// `stacked` in full screen, where the toggle has a row of its own above the header.
    @objc static func updateWindowControls(in sidebar: NSView, toggleFrame: NSRect, stacked: Bool) {
        ShellforgeSidebar.setWindowControls(windowControls(in: sidebar, toggleFrame: toggleFrame, stacked: stacked), on: sidebar)
    }

    // MARK: The sidebar's toggle

    /// The sidebar's one toggle, owned by the window rather than the sidebar so it stays where it is
    /// whether the sidebar is open or closed: just after the window buttons, as Finder's; in full
    /// screen, at the top of the panel or of the rail left when it is closed.
    @objc static func makeToggleButton(target: AnyObject, action: Selector) -> NSButton {
        let label = String(localized: "Shellforge.ToggleSidebar",
                           defaultValue: "Toggle Sidebar",
                           comment: "VoiceOver label of the button beside the window buttons that shows or hides Shellforge’s sidebar")
        let image = NSImage(systemSymbolName: SFSymbol.sidebarLeft.rawValue, accessibilityDescription: label)
        let button = NSButton(image: image ?? NSImage(), target: target, action: action)
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.setAccessibilityLabel(label)
        return button
    }

    /// The toggle's tooltip for a sidebar `hidden` or not.
    @objc static func toggleTooltip(hidden: Bool) -> String {
        if hidden {
            return String(localized: "Shellforge.ShowSidebarTooltip",
                          defaultValue: "Show Sidebar (⌃⌘S)",
                          comment: "Tooltip of the sidebar toggle while Shellforge’s sidebar is hidden; ⌃⌘S is its keyboard shortcut")
        }
        return String(localized: "Shellforge.HideSidebarTooltip",
                      defaultValue: "Hide Sidebar (⌃⌘S)",
                      comment: "Tooltip of the sidebar toggle while Shellforge’s sidebar shows; ⌃⌘S is its keyboard shortcut")
    }

    @objc static var toggleSize: NSSize { NSSize(width: 28, height: 22) }

    /// The header row's centre below the panel's top where no window buttons share it.
    @objc static var fullScreenHeaderMidY: CGFloat { Space.base + Size.menuRow / 2 }

    /// The toggle's frame in a root view of `rootHeight` (origin bottom-left): a gap past the zoom
    /// button and centred on it while the window shows its buttons; otherwise — full screen — on a
    /// row of its own at the panel's top, centred over the slim bar a closed sidebar leaves there, so
    /// it stays put open or closed.
    @objc static func toggleFrame(zoomButton: NSRect, hasWindowButtons: Bool, rootHeight: CGFloat) -> NSRect {
        let size = toggleSize
        if hasWindowButtons {
            return NSRect(x: zoomButton.maxX + Space.gap, y: zoomButton.midY - size.height / 2, width: size.width, height: size.height)
        }
        let midY = rootHeight - floatingInset - fullScreenHeaderMidY
        return NSRect(x: railWidth / 2 - size.width / 2, y: midY - size.height / 2, width: size.width, height: size.height)
    }

    /// The slim bar, in the terminal's colour, a closed sidebar leaves in full screen: the toggle's
    /// place, so there is something to see and click.
    @objc static var railWidth: CGFloat { 52 }

    /// How far the toggle's glyph sits inside its frame.
    static var toggleGlyphInset: CGFloat { 6 }

    /// The strip at the screen's left edge that reveals a closed sidebar in full screen.
    @objc static var revealEdgeWidth: CGFloat { 4 }

    /// What the sidebar last heard, for host tests: the zoom button's right edge and the buttons'
    /// centre from the sidebar's top.
    static func reportedWindowControls(of sidebar: NSView) -> (buttonsMaxX: CGFloat, buttonsMidY: CGFloat)? {
        ShellforgeSidebar.windowControls(of: sidebar).map { ($0.buttonsMaxX, $0.buttonsMidY) }
    }

    /// Where the toggle — and the window buttons before it — sit in the sidebar, so the header starts
    /// after it on its row; nil where the toggle is not over the sidebar.
    private static func windowControls(in sidebar: NSView, toggleFrame: NSRect, stacked: Bool) -> SidebarWindowControls? {
        guard floats, !sidebar.isHidden, let root = sidebar.superview else { return nil }
        let frame = root.convert(toggleFrame, to: sidebar)
        let midY = sidebar.isFlipped ? frame.midY : sidebar.bounds.height - frame.midY
        guard frame.minX >= 0, midY > 0, frame.maxX < sidebar.bounds.width else { return nil }
        return SidebarWindowControls(buttonsMaxX: frame.maxX, buttonsMidY: midY, stacked: stacked)
    }

    /// The drag handle's frame for a sidebar of `frame`.
    @objc static func dragHandleFrame(forSidebar frame: NSRect) -> NSRect {
        if floats {
            // The gap between the floating panel and the terminal, so it covers neither.
            return NSRect(x: frame.maxX, y: frame.minY, width: floatingInset, height: frame.height)
        }
        let handle = SidebarLayoutSettings.dragHandle(edge: frame.maxX, margin: CGFloat(iTermPreferences.sideMargins()))
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

    /// The user is hiding `sidebar` (⌃⌘S, its button, the window's toggle): Rearrange mode is cancelled.
    @objc static func sidebarWillHide(_ sidebar: NSView) { ShellforgeSidebar.willHide(sidebar) }
}

/// A closed sidebar in full screen comes back while the pointer wants it: the screen's left edge
/// reveals it over the terminal, and it goes again a moment after the pointer leaves it — unless the
/// pointer has come back, or a menu from it is open. Its toggle pins it open.
@objc(iTermShellforgeSidebarReveal)
final class ShellforgeSidebarReveal: NSObject {
    @objc private(set) var revealed = false
    /// Called whenever `revealed` changes.
    @objc var onChange: (() -> Void)?
    /// Asked when the delay is up: whether the panel should go now (the pointer is still away, no
    /// menu is open).
    @objc var shouldConceal: () -> Bool = { true }
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = 0

    static let concealDelay: TimeInterval = 0.3

    @objc override convenience init() {
        self.init(schedule: { delay, work in
            let timer = Timer(timeInterval: delay, repeats: false) { _ in work() }
            RunLoop.main.add(timer, forMode: .common)
        })
    }

    init(schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.schedule = schedule
    }

    /// The pointer reached the screen's left edge, or came back over the panel.
    @objc func pointerEntered() {
        generation += 1
        guard !revealed else { return }
        revealed = true
        onChange?()
    }

    /// The pointer left the panel: it goes after the delay, if it is still unwanted then.
    @objc func pointerExited() {
        guard revealed else { return }
        generation += 1
        let mine = generation
        schedule(Self.concealDelay) { [weak self] in
            guard let self, self.revealed, self.generation == mine else { return }
            if self.shouldConceal() {
                self.revealed = false
                self.onChange?()
            } else {
                self.pointerExited()
            }
        }
    }

    /// Back to closed and unrevealed: the sidebar opened for good, or full screen ended.
    @objc func reset() {
        generation += 1
        guard revealed else { return }
        revealed = false
        onChange?()
    }
}

/// An invisible view whose tracking area tells the reveal where the pointer is: the screen's left
/// edge while the sidebar is away, the panel and that edge while it is shown. It takes no clicks.
@objc(iTermShellforgeRevealTracker)
final class ShellforgeRevealTracker: NSView {
    @objc weak var reveal: ShellforgeSidebarReveal?

    /// Its tracking area from the start, following its visible rect as it grows and shrinks: AppKit
    /// does not always ask a view that starts hidden and of no size for its tracking areas later.
    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { it_fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { reveal?.pointerEntered() }
    override func mouseExited(with event: NSEvent) { reveal?.pointerExited() }
}
