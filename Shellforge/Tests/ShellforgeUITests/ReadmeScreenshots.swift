import AppKit
import Foundation
import ShellforgeDesign
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Whether this run draws the README's screenshots: only `scripts/render-screenshots.sh` asks, so the
/// normal suite never writes a file.
private let rendersScreenshots = ProcessInfo.processInfo.environment["SHELLFORGE_RENDER_SCREENSHOTS"] == "1"

/// The README's screenshots, drawn from code with made-up projects, tasks and readings: nothing here
/// reads the home folder, the Keychain, the defaults, `~/.ssh/config`, a git repository or the
/// network, so the pictures hold nothing of whoever renders them. Run `scripts/render-screenshots.sh`
/// after a change to what they show; the PNGs land in `docs/images/` as `<scene>-<dark|light>.png`.
@MainActor @Suite(.enabled(if: rendersScreenshots, "Set SHELLFORGE_RENDER_SCREENSHOTS=1 (scripts/render-screenshots.sh) to draw them"))
struct ReadmeScreenshots {
    @Test func render() async throws {
        let folder = Self.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for appearance in DemoAppearance.allCases {
            for scene in [DemoScene.sessions, .metrics, .rearrange, .ssh, .window] {
                let demo = try await DemoSidebar.make()
                let bitmap = try await demo.render(scene, appearance: appearance)
                try Self.write(bitmap, scene: scene, appearance: appearance, to: folder)
            }
            try Self.write(try await DemoNewTask.render(appearance: appearance), scene: .newTask, appearance: appearance, to: folder)
        }
    }

    /// `SHELLFORGE_SCREENSHOTS_DIR` when the script names it, else the package's `docs/images`.
    private static var outputFolder: URL {
        if let named = ProcessInfo.processInfo.environment["SHELLFORGE_SCREENSHOTS_DIR"], !named.isEmpty {
            return URL(fileURLWithPath: named, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/images", isDirectory: true)
    }

    private static func write(_ bitmap: NSBitmapImageRep, scene: DemoScene, appearance: DemoAppearance, to folder: URL) throws {
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("\(scene.rawValue)-\(appearance.rawValue).png"))
    }
}

private enum DemoScene: String {
    case sessions, metrics, rearrange, ssh, window, newTask = "new-task"

    /// The sidebar's height in the picture, at its default width: the Metrics and SSH panels are
    /// short, and the rest of a full-height one would be empty.
    var sidebarHeight: CGFloat { self == .metrics || self == .ssh ? 480 : 760 }

    /// Whether the scene draws the Sessions list, which fills between turns of the main actor.
    var showsSessions: Bool { self == .sessions || self == .rearrange || self == .window }
}

private enum DemoAppearance: String, CaseIterable {
    case dark, light
    var named: NSAppearance.Name { self == .dark ? .darkAqua : .aqua }
}

/// Draws `view` in an offscreen window of `appearance` at `size`, once `ready` holds, at 2×.
@MainActor
private func snapshot(_ view: some View, size: NSSize, appearance: DemoAppearance,
                      ready: @escaping (NSView) -> Bool = { _ in true }) async throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: AnyView(view))
    host.frame = NSRect(origin: .zero, size: size)
    let look = NSAppearance(named: appearance.named)
    host.appearance = look
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = look
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    // SwiftUI fills its List and runs the views' tasks between turns of the main actor.
    try #require(await eventually(describing: "the view to finish drawing") {
        host.layoutSubtreeIfNeeded()
        return ready(host)
    })
    host.layoutSubtreeIfNeeded()
    host.display()
    return try #require(Snapshot.bitmap(of: host))
}

/// The instant every reading is pinned to — Tuesday 10 November 2026, 09:30 UTC — and its calendar.
private enum DemoClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 30))!
    static var footer: FooterClock { FooterClock(now: now, calendar: calendar) }
    static func epoch(after interval: TimeInterval) -> Int { Int(now.addingTimeInterval(interval).timeIntervalSince1970) }
}

/// Hands out two CPU samples a quarter busy apart, then repeats the second; memory 61 % used.
private final class DemoSensor: MachineSensor, @unchecked Sendable {
    private let samples = Locked([DemoSensor.sample(busy: 0, idle: 0), DemoSensor.sample(busy: 23, idle: 77)])
    private static func sample(busy: UInt32, idle: UInt32) -> MachineSample {
        MachineSample(cpu: CPUTicks(user: busy, system: 0, idle: idle, nice: 0), memory: MemoryUse(used: 61, total: 100),
                      throttled: false, memoryPressure: false)
    }
    func sample() -> MachineSample { samples.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }
}

/// A sidebar with invented projects, tasks, a terminal and an SSH tunnel, every outside reading faked.
@MainActor
private struct DemoSidebar {
    let model: SidebarModel, activity: ActivityModel, hooks: AgentHooksModel, machine: MachineMonitor, folder: URL

    /// Everything under one scratch folder: the workspace, an empty home, a `PATH` holding only empty
    /// stand-ins for `claude` and `codex` (never run: only found), and an SSH config naming `staging`,
    /// the project's tunnel, and two other hosts for the SSH panel.
    static func make() async throws -> DemoSidebar {
        let folder = TestScratch.root.appendingPathComponent("readme-\(UUID().uuidString)")
        let home = folder.appendingPathComponent("home"), bin = folder.appendingPathComponent("bin")
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        for command in ["claude", "codex"] {
            let path = bin.appendingPathComponent(command).path
            #expect(fm.createFile(atPath: path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755]))
        }
        let sshConfig = folder.appendingPathComponent("ssh_config")
        try Data("""
            Host staging
              HostName staging.example.invalid
              LocalForward 5433 localhost:5432
            Host build-box
              HostName build.example.invalid
            Host db-replica
              HostName db.example.invalid

            """.utf8).write(to: sshConfig)
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": bin.path], source: .loginShell("/bin/zsh")) })
        let host = FakeTerminalHost(), feed = FakeFeed()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder.appendingPathComponent("workspace")))
        let model = SidebarModel(host: host, document: document, launcher: launcher, feed: feed,
                                 jiraSettings: { nil }, gitLabSettings: { nil }, gitHubSettings: { nil }, modelDefaults: { _ in [:] },
                                 sshConfig: SSHConfigSource(file: sshConfig, home: home), secrets: MemorySecretStore(), home: home)
        // Each project's host, without git: set before the workspace has a project to read.
        model.repositoryFacts = RepositoryFacts { path in
            let provider: Provider = path.hasSuffix("acme-web") ? .gitlab : path.hasSuffix("demo-api") ? .github : .git
            return SidebarModel.ProjectFacts(provider: provider, defaultBranch: "main")
        }
        let workspace = DemoWorkspace()
        try document.update { workspace.fill(&$0) }
        workspace.open(in: host, feed: feed)
        model.diffs = workspace.diffs
        await model.environmentRead?.value
        _ = await model.loadSSHHosts()
        try #require(await eventually(describing: "every project's host") { model.providers.count == workspace.projects.count })
        // No banner: an error or a fallback PATH would be drawn over the list.
        #expect(model.lastError == nil && model.environmentWarning == nil)

        let machine = MachineMonitor(sensor: DemoSensor(), power: InertPower())
        _ = await machine.sample()
        _ = await machine.sample()
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: home, resources: .bundled(resourceURL: nil)), names: [:])
        return DemoSidebar(model: model, activity: ActivityModel(source: ActivityOrderSource(defaults: nil)), hooks: hooks,
                           machine: machine, folder: folder)
    }

    func render(_ scene: DemoScene, appearance: DemoAppearance) async throws -> NSBitmapImageRep {
        switch scene {
        case .metrics: activity.select(.metrics)
        case .rearrange: model.beginRearrange()
        case .ssh: activity.select(.ssh)
        case .sessions, .window, .newTask: break
        }
        // The lock is one for every window: let it go whatever the drawing does.
        defer { if model.isRearranging { model.cancelRearrange() } }
        let chrome = SidebarChrome()
        if scene == .window { chrome.windowControls = DemoWindow.controls }
        let sidebar = SidebarView(model: model, activity: activity, chooseFolder: { nil }, hooks: hooks, machine: machine,
                               backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                               terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()), theme: ThemeSettings(defaults: ScratchDefaults.make()), appDefaults: ScratchDefaults.make(),
                               feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev), chrome: chrome,
                               showBackpack: { _ in }, showFeedback: { _ in }, hideSidebar: {}, agentTools: .none, agentsChanged: {})
            .interfaceScale(.standard)
            .environment(\.footerClock, DemoClock.footer)
        let view = scene == .window ? AnyView(DemoWindow(sidebar: sidebar, appearance: appearance)) : AnyView(sidebar)
        let width = scene == .window ? DemoWindow.width : Size.sidebarWidth
        let rows = model.rows.count
        return try await snapshot(view, size: NSSize(width: width, height: scene.sidebarHeight), appearance: appearance) { host in
            // The Sessions list has a row for each of the model's, plus its header outside Rearrange mode.
            !scene.showsSessions || Self.tables(in: host).contains { $0.numberOfRows >= rows }
        }
    }

    private static func tables(in view: NSView) -> [NSTableView] {
        view.subviews.flatMap { subview in (subview as? NSTableView).map { [$0] } ?? tables(in: subview) }
    }
}

/// The invented workspace: three projects, a review, a terminal, a tunnel, and the tabs and sessions
/// the daemon would report for them.
@MainActor
private struct DemoWorkspace {
    let acme = Project(name: "acme-web", path: "/Users/demo/code/acme-web")
    let api = Project(name: "demo-api", path: "/Users/demo/code/demo-api")
    let docs = Project(name: "docs-site", path: "/Users/demo/code/docs-site")
    var projects: [Project] { [acme, api, docs] }

    let login: TaskItem, flaky: TaskItem, review: TaskItem, rateLimit: TaskItem, guide: TaskItem
    let terminal: TerminalItem

    init() {
        func task(_ project: Project, _ title: String, _ branch: String, agent: String, kind: TaskKind = .task,
                  jira: JiraRef? = nil, mr: MergeRequestRef? = nil) -> TaskItem {
            TaskItem(projectId: project.id, title: title, branch: branch,
                     worktreePath: "\(project.path)/.worktrees/\(branch.split(separator: "/").last ?? "")", baseBranch: "main",
                     agent: agent, jira: jira, kind: kind, mr: mr)
        }
        login = task(acme, "Add login page", "feat/abc-123-add-login-page", agent: "claude",
                     jira: JiraRef(key: "ABC-123", summary: "Add login page", url: "https://jira.example.com/browse/ABC-123"))
        flaky = task(acme, "Fix flaky upload test", "fix/abc-131-flaky-upload-test", agent: "codex",
                     jira: JiraRef(key: "ABC-131", summary: "Fix flaky upload test", url: "https://jira.example.com/browse/ABC-131"))
        review = task(acme, "Review MR !42", "feat/abc-118-password-reset", agent: "claude", kind: .review,
                      mr: MergeRequestRef(iid: 42, title: "Password reset emails", url: "https://gitlab.example.com/acme/acme-web/-/merge_requests/42"))
        rateLimit = task(api, "Rate-limit the public API", "feat/api-77-rate-limit", agent: "claude")
        guide = task(docs, "Update the install guide", "docs/install-guide", agent: "codex")
        terminal = TerminalItem(projectId: api.id, name: "zsh")
    }

    func fill(_ workspace: inout Workspace) {
        var acme = self.acme
        acme.sshHost = "staging"
        acme.tunnels = [TunnelDefinition(alias: "staging")]
        workspace.projects = [acme, api, docs]
        for task in [login, flaky, review, rateLimit, guide] { workspace.addTask(task) }
        workspace.addTerminal(terminal)
    }

    var diffs: [UUID: DiffStat] {
        [login.id: DiffStat(added: 248, removed: 31), flaky.id: DiffStat(added: 12, removed: 9),
         rateLimit.id: DiffStat(added: 96, removed: 4), guide.id: DiffStat(added: 40, removed: 22)]
    }

    /// The window's tabs, “Add login page” selected, and what the daemon says of each.
    func open(in host: FakeTerminalHost, feed: FakeFeed) {
        let tabs: [(task: TaskItem?, agent: SessionAgent, state: SessionState, context: Int?)] = [
            (login, .claude, .working, 38), (flaky, .codex, .needsInput, 64), (review, .claude, .done, 21),
            (rateLimit, .claude, .done, 52), (guide, .codex, .idle, 12), (nil, .shell, .idle, nil),
        ]
        var snapshots: [TabSnapshot] = [], sessions: [SessionInfo] = []
        for (index, tab) in tabs.enumerated() {
            let id = "demo-session-\(index + 1)"
            let project = tab.task?.projectId ?? terminal.projectId
            snapshots.append(TabSnapshot(id: id, tabId: index + 1, title: tab.task?.title ?? terminal.name, taskId: tab.task?.id,
                                         projectId: project, terminalId: tab.task == nil ? terminal.id : nil))
            sessions.append(SessionInfo(sessionId: id, windowId: "demo-window", tabIndex: index, taskId: tab.task?.id.uuidString.lowercased(),
                                        projectId: project.uuidString.lowercased(), agent: tab.agent,
                                        model: tab.agent == .claude ? "opus" : tab.agent == .codex ? "gpt-5-codex" : nil,
                                        state: tab.state, title: tab.task?.title ?? terminal.name,
                                        cwd: tab.task?.worktreePath ?? api.path, active: index == 0, contextPercent: tab.context,
                                        tokens: tab.task == nil ? nil : TokenTally(input: 182_400 / (index + 1), cached: 120_000 / (index + 1),
                                                                                   output: 14_600 / (index + 1)),
                                        reportedAt: DemoClock.now.timeIntervalSince1970))
        }
        host.tabs = snapshots
        host.selectedTabId = snapshots[0].id
        var snapshot = DaemonSnapshot(protocolVersion: 1, connected: true, sessions: sessions, usage: UsageSnapshot(
            claude: Usage(fiveHour: UsageWindow(usedPercent: 42, resetsAt: DemoClock.epoch(after: 2 * 3600 + 35 * 60)),
                          sevenDay: UsageWindow(usedPercent: 73, resetsAt: DemoClock.epoch(after: 3 * 86400 + 5 * 3600)),
                          spend: nil, plan: "max", updatedAt: DemoClock.epoch(after: -60)),
            codex: Usage(fiveHour: UsageWindow(usedPercent: 18, resetsAt: DemoClock.epoch(after: 4 * 3600)),
                         sevenDay: UsageWindow(usedPercent: 35, resetsAt: DemoClock.epoch(after: 5 * 86400)),
                         spend: nil, plan: "plus", updatedAt: DemoClock.epoch(after: -120))))
        // The tunnel's uptime is drawn against the wall clock: two hours and five minutes before it.
        snapshot.tunnels = [TunnelInfo(alias: "staging", state: .up, error: nil, since: Date().timeIntervalSince1970 - 7_500,
                                       bytesIn: 34_000_000, bytesOut: 820_000)]
        var store = SessionStore()
        store.apply(.snapshot(snapshot))
        feed.store = store
        host.onChange?()
    }
}

/// The New Task sheet in `acme-web`, filled in from a ticket, with the SSH host to open beside it.
@MainActor
private enum DemoNewTask {
    static func render(appearance: DemoAppearance) async throws -> NSBitmapImageRep {
        let ticket = JiraTicket(key: "ABC-123", summary: "Add login page", description: "Email and password sign-in for the web app.",
                                issueType: "Story", status: "To Do", url: "https://jira.example.com/browse/ABC-123")
        var draft = TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil)
        draft.paneHost = "staging"
        draft.apply(ticket: ticket)
        let model = NewTaskModel(project: Project(name: "acme-web", path: "/Users/demo/code/acme-web"), agents: AgentPresets.all,
                                 available: ["claude", "codex"], draft: draft, rememberedModels: [:],
                                 catalogue: { _ in [] }, branches: { ["main", "develop"] }, submit: { _ in },
                                 searchIssues: { _ in [ticket] }, sshHost: "staging",
                                 home: TestScratch.root.appendingPathComponent("readme-sheet-home-\(UUID().uuidString)"))
        return try await snapshot(NewTaskSheet(model: model, dismiss: {}), size: NSSize(width: Sheet.width, height: Sheet.height),
                                  appearance: appearance) { _ in model.draft.ticket == ticket && !model.ticketsOpen }
    }
}

/// A whole window: the sidebar, window buttons over its top, and the selected task's tab split into
/// its Claude Code pane and a shell beside it, in the terminal colours Match Terminal sets. The
/// panes are drawn, not run: every line in them is invented.
@MainActor
private struct DemoWindow: View {
    let sidebar: AnyView
    let appearance: DemoAppearance

    static let width: CGFloat = Size.sidebarWidth + 860
    static let controls = SidebarWindowControls(buttonsMaxX: 72, buttonsMidY: 22)

    init(sidebar: some View, appearance: DemoAppearance) {
        self.sidebar = AnyView(sidebar)
        self.appearance = appearance
    }

    var body: some View {
        let colors = ShellforgeTerminalPalette.colors(in: NSAppearance(named: appearance.named))
        let color = { (role: TerminalColorRole) in colors[role].map { Color(.sRGB, red: $0.red, green: $0.green, blue: $0.blue) } ?? .primary }
        HStack(spacing: 0) {
            sidebar.frame(width: Size.sidebarWidth)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    DemoPane(lines: DemoPane.claude, color: color).frame(maxHeight: .infinity)
                    // Claude Code's input, pinned to the foot of its pane.
                    Text(">").foregroundColor(color(.foreground))
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(color(.ansi(8)), lineWidth: 1))
                        .padding(.horizontal, 14)
                    DemoPane(lines: DemoPane.claudeFooter, color: color).fixedSize(horizontal: false, vertical: true)
                }
                Rectangle().fill(color(.ansi(8)).opacity(0.5)).frame(height: 1)
                DemoPane(lines: DemoPane.shell, color: color).frame(height: 250)
            }
            .background(color(.background))
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { Circle().fill($0).frame(width: 12, height: 12) }
            }
            .padding(.leading, 20).padding(.top, Self.controls.buttonsMidY - 6)
        }
    }
}

/// One terminal pane: lines of coloured runs in the terminal's monospaced font.
private struct DemoPane: View {
    struct Run { var text: String; var role: TerminalColorRole = .foreground; var bold = false }
    let lines: [[Run]]
    let color: (TerminalColorRole) -> Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines.indices, id: \.self) { index in
                lines[index].reduce(Text("")) { line, run in
                    line + Text(run.text).foregroundColor(color(run.role)).fontWeight(run.bold ? .semibold : .regular)
                }
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func plain(_ text: String) -> [Run] { [Run(text: text)] }
    private static let bullet = Run(text: "⏺ ", role: .ansi(2))
    private static func tool(_ name: String, _ argument: String, _ result: String) -> [[Run]] {
        [[bullet, Run(text: name, bold: true), Run(text: "(\(argument))")], [Run(text: "  ⎿  ", role: .ansi(8)), Run(text: result, role: .ansi(8))], []]
    }

    static let claude: [[Run]] = [
        [Run(text: "> ", role: .ansi(8)), Run(text: "Add the login page from ABC-123: email and password, with an error under each field.")],
        [],
        [bullet, Run(text: "I’ll add a LoginPage with a form, wire it to the existing auth client, and cover it with tests.")],
        [],
    ] + tool("Read", "src/auth/client.ts", "Read 64 lines")
      + tool("Write", "src/pages/LoginPage.tsx", "Wrote 112 lines to src/pages/LoginPage.tsx")
      + tool("Update", "src/routes.tsx", "Updated src/routes.tsx with 3 additions")
      + tool("Bash", "npm test -- LoginPage", "PASS  src/pages/LoginPage.test.tsx (6 tests)")
      + [
        [Run(text: "✻ ", role: .ansi(3)), Run(text: "Showing errors under each field…", role: .ansi(3)), Run(text: " (esc to interrupt)", role: .ansi(8))],
    ]
    static let claudeFooter: [[Run]] = [[Run(text: "  ⏵⏵ accept edits on", role: .ansi(5))]]

    private static let prompt: [Run] = [Run(text: "acme-web", role: .ansi(4), bold: true), Run(text: " abc-123-add-login-page", role: .ansi(6)),
                                        Run(text: " ❯ ", role: .ansi(2))]
    static let shell: [[Run]] = [
        prompt + plain("git status --short"),
        [Run(text: " M ", role: .ansi(1)), Run(text: "src/routes.tsx")],
        [Run(text: "?? ", role: .ansi(1)), Run(text: "src/pages/LoginPage.test.tsx")],
        [Run(text: "?? ", role: .ansi(1)), Run(text: "src/pages/LoginPage.tsx")],
        prompt + plain("npm run dev"),
        [],
        [Run(text: "  VITE", role: .ansi(2), bold: true), Run(text: " ready in 412 ms", role: .ansi(8))],
        [Run(text: "  ➜  ", role: .ansi(2)), Run(text: "Local:   ", bold: true), Run(text: "http://localhost:5173/", role: .ansi(6))],
    ]
}
