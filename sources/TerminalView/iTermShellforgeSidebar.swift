//
//  iTermShellforgeSidebar.swift
//  Shellforge
//
//  Hands the Shellforge sidebar, which lives in the Shellforge package, to the Objective-C window
//  code, and implements its TerminalHost over one PseudoTerminal's tabs.
//

import AppKit
import ShellforgeCore
import ShellforgeUI

@objc(iTermShellforgeSidebar)
@MainActor
final class iTermShellforgeSidebar: NSObject {
    /// The sidebar column's width in points.
    @objc static var width: CGFloat { ShellforgeSidebar.width }

    /// One shared launcher, so the login shell's environment is read once per app run.
    nonisolated static let launcher = CommandLauncher()

    /// The one workspace every window's sidebar shows and changes.
    static let document = WorkspaceDocument(store: WorkspaceStore())

    /// A new sidebar for `windowController`'s window.
    @objc static func makeView(for windowController: PseudoTerminal) -> NSView {
        let host = iTermShellforgeHost(windowController: windowController)
        let model = SidebarModel(host: host, document: document, launcher: launcher, feed: link)
        return ShellforgeSidebar.makeView(model: model, chooseFolder: {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Add Project"
            return panel.runModal() == .OK ? panel.url?.path : nil
        })
    }

    /// The default profile changed to run the login shell in `directory`.
    nonisolated static func taskTabProfile(base: [AnyHashable: Any], directory: String) -> [AnyHashable: Any] {
        var profile = base
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
                // Session-created fires before the session joins a tab; read the window next turn.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.onChange?()
                        // A tab opened, closed or moved: the daemon hears it now, not on the next tick.
                        iTermShellforgeSidebar.link.reportsMayHaveChanged()
                    }
                }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var tabs: [TabSnapshot] {
        (windowController?.tabs() ?? []).compactMap { tab in
            guard let session = tab.activeSession else { return nil }
            let scope = session.genericScope
            return TabSnapshot(id: session.guid, tabId: Int(tab.uniqueId), title: session.name,
                               taskId: (scope.value(forVariableName: ShellforgeTags.task) as? String).flatMap(UUID.init(uuidString:)),
                               projectId: (scope.value(forVariableName: ShellforgeTags.project) as? String).flatMap(UUID.init(uuidString:)))
        }
    }

    var selectedTabId: String? { windowController?.currentTab()?.activeSession?.guid }

    func select(tab id: String) {
        guard let tab = windowController?.tabs().first(where: { $0.activeSession?.guid == id }),
              let item = tab.tabViewItem else { return }
        item.tabView?.selectTabViewItem(item)
        onChange?()
    }

    func openTab(in directory: String, taskId: UUID, projectId: UUID, title: String) {
        guard let windowController, let base = ProfileModel.sharedInstance()?.defaultBookmark() else { return }
        let profile = iTermShellforgeSidebar.taskTabProfile(base: base, directory: directory)
        iTermSessionLauncher.launchBookmark(profile, in: windowController, style: .tab, withURL: nil,
                                            hotkeyWindowType: .none, makeKey: true, canActivate: true,
                                            respectTabbingMode: false, index: nil, command: nil,
                                            makeSession: nil, didMakeSession: { session in
            session.genericScope.setValue(taskId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.task)
            session.genericScope.setValue(projectId.uuidString.lowercased(), forVariableNamed: ShellforgeTags.project)
        }, completion: { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        })
    }
}

/// The app's one helper: started at launch, told about every session, stopped at quit.
extension iTermShellforgeSidebar {
    /// The daemon's package is copied to `Contents/Resources/daemon/shellforged`, alone in its folder:
    /// that folder is the daemon's PYTHONPATH, and iTerm2's own scripts sit at the top of Resources.
    static let link = DaemonLink(daemonDir: Bundle.main.resourceURL?.appendingPathComponent("daemon"),
                                 findPython: { PythonFinder.find(launcher: launcher).map(URL.init(fileURLWithPath:)) },
                                 reports: { allReports() })
    private static var tick: Timer?

    /// Starts the helper and the report tick; both stop at iTermApplicationWillTerminate.
    @objc static func startHelper() {
        // ModernTests run inside the app; a test run must not start, adopt or stop a real helper.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        link.start()
        // jobPid and commandLine change with no notification; the tick reads them, and only a
        // changed list is sent.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { link.reportsMayHaveChanged() }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name(iTermApplicationWillTerminate), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                tick?.invalidate()
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
