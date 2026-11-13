// Ported from AiTerm (app/Sources/AiTerm/Views/SidebarRows.swift: SidebarHeader, ProjectHeaderRow,
// TaskRowView, TerminalRowView, and SidebarView.swift: SidebarBanners, SidebarBanner),
// GPLv3, Laurens D'Hondt. Each reads Shellforge's model where AiTerm's read its AppController. The
// terminal row is in Terminals/TerminalRowView.swift; AiTerm's Pull Default Branch and Remove
// Project are not ported yet.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// `PROJECTS`, the Agent hooks and New Tab in Home Folder buttons, the menu that adds a project, and
/// Hide Sidebar. Settings is the activity bar's gear alone.
struct SidebarHeader: View {
    let addProject: () -> Void
    var addDivider: () -> Void = {}
    /// Greyed with no project: a divider would divide nothing.
    var canAddDivider = true
    let showHooks: () -> Void
    /// A shell of no project, in the home folder.
    var newHomeTab: () -> Void = {}
    /// ⌃⌘S as a button; while hidden, the window's title bar shows the same icon to bring it back.
    var hideSidebar: () -> Void = {}
    /// Set while the window's buttons sit inside the sidebar: the header is pinned below their band,
    /// and the sidebar toggle is the window's.
    var windowControls: SidebarWindowControls? = nil
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        HStack {
            SidebarHeading("Projects")
            Spacer()
            Button(action: showHooks) {
                Image(symbol: .boltHorizontalCircle).font(Typography.label).foregroundStyle(surface.secondaryInk)
            }
            .buttonStyle(.plain)
            .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
            .help("Agent hooks")
            .accessibilityLabel("Agent hooks")
            Button(action: newHomeTab) {
                Image(symbol: .terminal).font(Typography.label).foregroundStyle(surface.secondaryInk)
            }
            .buttonStyle(.plain)
            .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
            .help("New Tab in Home Folder")
            .accessibilityLabel("New Tab in Home Folder")
            AddMenu(help: "Add project", enabled: true) {
                Button("Add Project…", action: addProject)
                Button("Add Divider…", action: addDivider).disabled(!canAddDivider)
            }
            // Last, at the sidebar's edge: the side it folds away to — unless the window holds the
            // toggle, at the start of this row, where it stays when the sidebar is closed.
            if windowControls == nil {
                Button(action: hideSidebar) {
                    Image(symbol: .sidebarLeft).font(Typography.label).foregroundStyle(surface.secondaryInk)
                }
                .buttonStyle(.plain)
                .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
                .help("Hide Sidebar (⌃⌘S)")
                .accessibilityLabel("Hide Sidebar")
            }
        }
        .frame(height: scale(Size.menuRow))
        .background(ViewMark(name: Self.markName))
        .modifier(HeaderPlacement(windowControls: windowControls, scale: scale))
    }

    /// The header's `ViewMark`, also on another panel's title in its place.
    static let markName = "SidebarHeader"
}

/// The header's place: a row of the list as before, or — while the window's buttons sit inside the
/// sidebar — pinned at the top of the panel column, below the buttons' band and beside the activity
/// bar, its title and trailing buttons in line with the rows' below.
struct HeaderPlacement: ViewModifier {
    let windowControls: SidebarWindowControls?
    let scale: InterfaceScale

    func body(content: Content) -> some View {
        if windowControls != nil {
            // Outside the list, so its inset is added to the rows' own.
            content
                .padding(.leading, SidebarRowLayout.listInset + scale(Space.base))
                .padding(.trailing, SidebarRowLayout.trailingInset(scale) + SidebarRowLayout.listInset)
                .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
        } else {
            content
                .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
                .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
        }
    }
}

/// A project: its chevron, its provider's mark, its name and Jira badge, and the "+" that starts a
/// task; right-clicked, AiTerm's menu: the "+" items, Open in, Jira Projects…, Tunnels… and SSH
/// Host…, Pull <default branch> for a hosted project, then Rearrange, and Remove Project… last.
struct ProjectHeaderRow: View {
    let node: ProjectNode
    let collapsed: Bool
    let provider: Provider
    /// Its tasks' statuses: a folded project shows them as AiTerm's count chips.
    let statuses: [SessionState]
    let toggle: () -> Void
    let newTask: () -> Void
    let newReview: () -> Void
    var newTerminal: () -> Void = {}
    /// Rearrange mode, greyed while another window is in it.
    var canRearrange = true
    var rearrange: () -> Void = {}
    let editJiraProjects: () -> Void
    var editTunnels: () -> Void = {}
    var editSSHHost: () -> Void = {}
    /// The project's SSH host in a tab of its own; offered only while it is in ~/.ssh/config.
    var openSSHHost: () -> Void = {}
    var canOpenSSHHost = false
    /// Remove Project…: asks, then forgets the project; files and tabs stay.
    var remove: () -> Void = {}
    /// "Pull main", offered for a project on GitLab or GitHub; nil hides it.
    var pullTitle: String?
    var pulling = false
    var pull: () -> Void = {}
    /// Branch Names: the format New Task uses, and its change.
    var branchFormat = BranchFormat.typeAndName
    var setBranchFormat: (BranchFormat) -> Void = { _ in }
    @Environment(\.interfaceScale) private var scale
    @Environment(\.isRearranging) private var isRearranging

    /// An empty project has nothing to fold; its terminals are something.
    private var collapses: Bool { Self.collapses(node) }

    static func collapses(_ node: ProjectNode) -> Bool {
        !node.tasks.isEmpty || !node.terminals.isEmpty || !node.project.tunnels.isEmpty
    }

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            // Only the label folds the section; the "+" keeps its own click.
            HStack(spacing: scale(Space.base)) {
                HeaderChevron(collapsed: collapsed).frame(width: SidebarRowLayout.chevronWidth(scale))
                    .opacity(collapses ? 1 : 0)
                ProviderIcon(provider: provider)
                // The name, then its Jira badge and any `+n`, `Space.gap` apart as a task row's quiet
                // badges and branch are. They keep their width; the name is what truncates.
                HStack(spacing: scale(Space.gap)) {
                    if let alias = node.project.sshHost {
                        HeaderTitle(text: node.project.name).help("SSH host: \(alias)")
                    } else {
                        HeaderTitle(text: node.project.name)
                    }
                    if let badge = ProjectJiraBadge.badge(for: node.project) {
                        ProjectJiraBadgeView(badge: badge, canChangeWorkspace: true, editProjects: editJiraProjects)
                            // In Rearrange mode only the fold stays live.
                            .allowsHitTesting(!isRearranging)
                    }
                }
                Spacer(minLength: scale(Space.tight))
                // Only when folded: unfolded, the task rows say all of this and more.
                if collapsed { StatusCountChips(counts: StatusCount.of(statuses)) }
            }
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded(toggle), including: collapses ? .all : .subviews)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(collapses ? .isButton : [])
            AddMenu(help: "New task or review", enabled: true) { newItems }
                .allowsHitTesting(!isRearranging)
        }
        .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: false))
        .modifier(RearrangeAccessibilityAction(canRearrange: canRearrange, action: rearrange))
        .modifier(BranchFormatAccessibilityActions(current: branchFormat, enabled: !isRearranging, set: setBranchFormat))
        // AiTerm's order: what the "+" offers, Open in, what the project links to, Rearrange, then Remove.
        .rowContextMenu {
            newItems
            Divider()
            OpenInMenuItems(folder: node.project.path)
            Divider()
            Button("Jira Projects…", action: editJiraProjects)
            Button("Tunnels…", action: editTunnels)
            Button(SidebarModel.sshHostMenuTitle(node.project.sshHost), action: editSSHHost)
            // After the SSH host's own items, which stay together.
            if let alias = node.project.sshHost, canOpenSSHHost { Button(SidebarModel.openSSHHostTitle(alias), action: openSSHHost) }
            Menu(Self.branchNamesTitle) {
                ForEach(BranchFormat.allCases, id: \.self) { format in
                    Toggle(format.menuTitle, isOn: Binding(get: { branchFormat == format }, set: { _ in setBranchFormat(format) }))
                }
            }
            if let pullTitle {
                Divider()
                Button(pullTitle, action: pull).disabled(pulling)
            }
            Divider()
            RearrangeMenuItem(enabled: canRearrange, action: rearrange)
            Divider()
            Button("Remove Project…", role: .destructive, action: remove)
        }
    }

    static let branchNamesTitle = "Branch Names"

    /// What VoiceOver offers for the same choice, as one action each, the one in use saying so as
    /// the menu's checkmark does.
    static func voiceOverBranchAction(_ format: BranchFormat, current: BranchFormat) -> String {
        "\(branchNamesTitle): \(format.menuTitle)" + (format == current ? " (current)" : "")
    }

    /// The context menu's items, in order, apart from Open in's.
    static func menuTitles(provider: Provider, sshHost: String?, canOpenSSHHost: Bool, pullTitle: String?) -> [String] {
        var titles = ["New Task…", "New Review…", "New Terminal…", "Jira Projects…", "Tunnels…", SidebarModel.sshHostMenuTitle(sshHost)]
        if let sshHost, canOpenSSHHost { titles.append(SidebarModel.openSSHHostTitle(sshHost)) }
        titles.append(branchNamesTitle)
        if let pullTitle { titles.append(pullTitle) }
        return titles + [RearrangeMenuItem.title, "Remove Project…"]
    }

    /// What the "+" and the context menu both offer. New Review is greyed only for a folder that is
    /// no repository at all (`.none`); a repository without a remote reads as plain git, and a
    /// review of one of its local branches works — its branch is then left as it was on removal.
    @ViewBuilder private var newItems: some View {
        Button("New Task…", action: newTask)
        Button("New Review…", action: newReview).disabled(provider == .none)
        Button("New Terminal…", action: newTerminal)
    }
}

/// One task: its agents, its title, its branch, and its status.
struct TaskRowView: View {
    let node: TaskNode
    let selected: Bool
    let agents: [SessionAgent]
    let status: SessionState
    /// The status is guessed from the terminal: its dot's tooltip says so.
    var guessed = false
    /// What each agent mark's tooltip calls its agent.
    var agentName: @MainActor (SessionAgent) -> String = { $0.rawValue }
    /// Its removal, running or stopped; nil when none.
    var removal: RowRemoval? = nil
    let activate: () -> Void
    var remove: () -> Void = {}
    var rename: () -> Void = {}
    /// Its current tab's Close Tab (Close Pane when split); the last pane asks to remove the task.
    var closeTab: () -> Void = {}
    var closeTitle = "Close Tab"
    /// Its worktree's lines against its base, for the VS Code badge; nil until read.
    var diff: DiffStat? = nil
    /// Rearrange mode, greyed while another window is in it.
    var canRearrange = true
    var rearrange: () -> Void = {}
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        SelectableRow(selected: selected, activate: activate) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: Self.marks(agents), name: agentName)
                VStack(alignment: .leading, spacing: scale(Space.tight)) {
                    RowTitle(node.task.title)
                    // A removal says so in the badge line's place and at its height, so the row keeps its own.
                    if let caption = Self.caption(removal) {
                        RowCaption(caption.text, warns: caption.warns).frame(height: scale(Size.chip))
                    } else {
                        // The ticket, then the branch — the branch last because it is the one thing that
                        // truncates. Quiet badges carry no box, so `Space.gap` is what keeps them apart.
                        HStack(spacing: scale(Space.gap)) {
                            if let ticket = TaskTicketBadge(jira: node.task.jira) {
                                Badge(ticket.label, icon: .brand(Palette.jira), help: ticket.help, style: .quiet,
                                      action: ticket.url.map { url in { ExternalLink.open(url) } })
                            }
                            if let request = TaskRequestBadge(mr: node.task.mr) {
                                Badge(request.label, icon: .brand(request.host.brand), help: request.help, style: .quiet,
                                      action: { ExternalLink.open(request.url) })
                            }
                            VSCodeBadge(folder: node.task.worktreePath, diff: diff, base: node.task.baseBranch)
                            BranchLabelView(label: BranchLabel(name: node.task.branch, extra: 0, drifted: false, detail: ""))
                                .layoutPriority(1)
                        }
                    }
                }
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: status, size: SidebarRowLayout.trailingGlyph(scale), guessed: guessed)
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel(node.task.title)
        .accessibilityValue(status.label)
        .modifier(RearrangeAccessibilityAction(canRearrange: canRearrange, action: rearrange))
        .rowContextMenu {
            // Greyed while the row is being removed, as AiTerm's is.
            Button("Rename…", action: rename).disabled(removal == .removing)
            Divider()
            OpenInMenuItems(folder: node.task.worktreePath)
            Divider()
            RearrangeMenuItem(enabled: canRearrange, action: rearrange)
            Divider()
            if !node.tabs.isEmpty { Button(closeTitle, action: closeTab).disabled(removal == .removing) }
            Button("Remove \(node.task.kindName)…", role: .destructive, action: remove).disabled(removal == .removing)
        }
    }

    /// The context menu's items, in order, apart from Open in's.
    static func menuTitles(hasTabs: Bool, closeTitle: String, kindName: String) -> [String] {
        ["Rename…", RearrangeMenuItem.title] + (hasTabs ? [closeTitle] : []) + ["Remove \(kindName)…"]
    }

    /// What the row says of its removal: "Removing…" while it runs, why it stopped after.
    static func caption(_ removal: RowRemoval?) -> (text: String, warns: Bool)? {
        switch removal {
        case nil: nil
        case .removing: ("Removing…", false)
        case .stopped(let note): (note, true)
        }
    }

    /// AiTerm's task row: the agents it was told of, and none when there are none.
    static func marks(_ agents: [SessionAgent]) -> AvatarGroup { AvatarGroup.of(agents) }
}

/// One tab, drawn as AiTerm draws a terminal row — its agents, its title, its status — one step
/// further in than its task.
struct TabRowView: View {
    let tab: TabSnapshot
    let selected: Bool
    let agents: [SessionAgent]
    let status: SessionState
    /// The status is guessed from the terminal: its dot's tooltip says so.
    var guessed = false
    /// What each agent mark's tooltip calls its agent.
    var agentName: @MainActor (SessionAgent) -> String = { $0.rawValue }
    let activate: () -> Void
    var close: () -> Void = {}
    /// "Close Tab", or "Close Pane" on a tab split with ⌘D.
    var closeTitle = "Close Tab"
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        SelectableRow(selected: selected, activate: activate) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: Self.marks(agents), name: agentName)
                RowTitle(tab.title)
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: status, size: SidebarRowLayout.trailingGlyph(scale), guessed: guessed)
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .padding(.leading, scale(Space.section))
        .accessibilityLabel(tab.title)
        .accessibilityValue(status.label)
        .accessibilityAction(named: Text(closeTitle), close)
        .contextMenu { Button(closeTitle, action: close) }
    }

    /// AiTerm's terminal row: its agents, or its shell's `>_` when none is known.
    static func marks(_ agents: [SessionAgent]) -> AvatarGroup { AvatarGroup.of(agents.isEmpty ? [.shell] : agents) }
}

/// What the sidebar has to say before its rows: the helper's problem, the last action's failure,
/// what is being done.
struct SidebarBanners: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var feedback: FeedbackPrompt
    let giveFeedback: () -> Void

    var body: some View {
        if let warning = model.environmentWarning {
            SidebarBanner(text: warning, tone: .warning)
        }
        if model.helper.isProblem {
            SidebarBanner(text: model.helper.text, tone: model.helper == .helperUnreachable ? .info : .warning, trailing: Space.block)
        }
        if let error = model.lastError {
            SidebarBanner(text: error, tone: .error, dismiss: model.dismissError)
        }
        if let working = model.working {
            SidebarBanner(text: working, tone: .info)
        }
        if let notice = model.notice {
            SidebarBanner(text: notice, tone: .info)
        }
        if feedback.showsBanner {
            FeedbackBanner(prompt: feedback, giveFeedback: giveFeedback)
        }
    }
}

struct SidebarBanner: View {
    enum Tone { case error, warning, info }

    /// A banner's `ViewMark`.
    static let markName = "SidebarBanner"

    let text: String
    let tone: Tone
    var trailing: CGFloat = Space.base
    var vertical: CGFloat = Space.snug
    /// An × at the end that clears the banner; none when nil.
    var dismiss: (() -> Void)?

    /// The notice's text colour: readable on its tinted ground; the colour is the symbol's.
    static func textInk(for tone: Tone) -> Color {
        switch tone {
        case .error, .warning: Palette.text
        case .info: Palette.muted
        }
    }

    /// The notice's symbol, by tone.
    static func symbol(for tone: Tone) -> SFSymbolName {
        switch tone {
        case .error: .xmarkOctagonFill
        case .warning: .exclamationmarkTriangleFill
        case .info: .infoCircleFill
        }
    }

    /// The notice's tinted ground, by tone.
    static func ground(for tone: Tone) -> Color {
        switch tone {
        case .error: Palette.noticeError
        case .warning: Palette.noticeWarning
        case .info: Palette.noticeInfo
        }
    }

    /// The symbol's colour: the tone's own.
    static func symbolInk(for tone: Tone) -> Color {
        switch tone {
        case .error: Palette.destructive
        case .warning: Palette.amber
        case .info: Palette.muted
        }
    }

    var body: some View {
        NoticeGround(tone: tone, trailing: trailing, vertical: vertical) {
            NoticeLine(text: text, tone: tone, dismiss: dismiss)
        }
        .background(ViewMark(name: Self.markName))
    }
}

/// A notice's symbol and text, and an × when it can be dismissed.
struct NoticeLine: View {
    let text: String
    let tone: SidebarBanner.Tone
    var dismiss: (() -> Void)?
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: scale(Space.snug)) {
            Image(symbol: SidebarBanner.symbol(for: tone)).font(Typography.help).foregroundStyle(SidebarBanner.symbolInk(for: tone))
                .accessibilityHidden(true)
            Text(text).font(Typography.help).foregroundStyle(SidebarBanner.textInk(for: tone)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let dismiss {
                Button(action: dismiss) {
                    Image(symbol: .xmark).font(Typography.help).foregroundStyle(surface.secondaryInk)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
    }
}

/// An inline notice's ground: tinted and rounded, lined up with the rows below it.
struct NoticeGround<Content: View>: View {
    let tone: SidebarBanner.Tone
    var trailing: CGFloat = Space.base
    var vertical: CGFloat = Space.snug
    @ViewBuilder let content: Content
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        content
            .padding(.horizontal, scale(Space.base))
            .padding(.vertical, scale(Space.snug))
            .background(RoundedRectangle(cornerRadius: scale(Radius.group), style: .continuous).fill(SidebarBanner.ground(for: tone)))
            .padding(.leading, scale(Space.inset))
            .padding(.trailing, scale(trailing))
            .padding(.vertical, scale(vertical) / 2)
    }
}

/// Turns off AppKit's own selection highlight on the sidebar's tables, so the row pill is the only
/// painter (AiTerm's `NativeRowHighlight`, without its global swizzle of NSTableView's context-menu
/// highlight, which inside iTerm2 would reach iTerm2's own tables).
struct NativeRowHighlight: NSViewRepresentable {
    static let off = NativeRowHighlight()

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func layout() { super.layout(); apply() }

        /// The sidebar's tables: its list and the activity bar's.
        private var found = NSHashTable<NSTableView>.weakObjects()

        func apply() {
            let known = found.allObjects
            if !known.isEmpty, known.allSatisfy({ $0.window != nil && $0.window === window }) {
                known.forEach { $0.selectionHighlightStyle = .none }
                return
            }
            func tables(in view: NSView) -> [NSTableView] {
                if let table = view as? NSTableView { return [table] }
                return view.subviews.flatMap { tables(in: $0) }
            }
            // Up to the sidebar's own host and no further: past it are iTerm2's views and tables.
            var ancestor = superview
            while let current = ancestor {
                let inside = tables(in: current)
                if !inside.isEmpty {
                    found.removeAllObjects()
                    for table in inside {
                        table.selectionHighlightStyle = .none
                        found.add(table)
                    }
                    return
                }
                if current is RowHighlightBoundary { return }
                ancestor = current.superview
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) { view.apply() }
}

/// The view `NativeRowHighlight` looks no further than: the sidebar's hosting view.
protocol RowHighlightBoundary: NSView {}

extension BranchFormat {
    /// The Branch Names item for it.
    var menuTitle: String {
        switch self {
        case .typeAndName: "Type and Name"
        case .ticketKey: "Ticket Key Only"
        }
    }
}

/// The Branch Names choices as VoiceOver actions, left out in Rearrange mode like the menu.
private struct BranchFormatAccessibilityActions: ViewModifier {
    let current: BranchFormat
    let enabled: Bool
    let set: (BranchFormat) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(action(.typeAndName))
            .modifier(action(.ticketKey))
    }

    private func action(_ format: BranchFormat) -> NamedAccessibilityAction {
        NamedAccessibilityAction(name: ProjectHeaderRow.voiceOverBranchAction(format, current: current), enabled: enabled, action: { set(format) })
    }
}
