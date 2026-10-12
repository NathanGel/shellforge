// Ported from AiTerm (app/Sources/AiTerm/Views/SidebarRows.swift: SidebarHeader, ProjectHeaderRow,
// TaskRowView, TerminalRowView, and SidebarView.swift: SidebarBanners, SidebarBanner),
// GPLv3, Laurens D'Hondt. Each reads Shellforge's model where AiTerm's read its AppController; what Shellforge
// does not have yet — reviews, terminals, VS Code badges, removal — is left out, not stubbed.
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// `PROJECTS`, the menu that adds a project, and the Agent hooks button.
struct SidebarHeader: View {
    let addProject: () -> Void
    let showHooks: () -> Void
    let showMacSettings: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        HStack {
            SidebarHeading("Projects")
            Spacer()
            Button(action: showHooks) {
                Image(systemName: "bolt.horizontal.circle").font(Typography.label).foregroundStyle(surface.secondaryInk)
            }
            .buttonStyle(.plain)
            .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
            .help("Agent hooks")
            .accessibilityLabel("Agent hooks")
            Button(action: showMacSettings) {
                Image(systemName: "gearshape").font(Typography.label).foregroundStyle(surface.secondaryInk)
            }
            .buttonStyle(.plain)
            .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
            .help("Settings…")
            .accessibilityLabel("Settings")
            AddMenu(help: "Add project", enabled: true) {
                Button("Add Project…", action: addProject)
            }
        }
        .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .padding(.top, scale(Space.base)).padding(.bottom, scale(Space.tight))
    }
}

/// A project: its chevron, its provider's mark, its name and Jira badge, and the "+" that starts a
/// task; right-clicked, New Task… and Jira Projects….
struct ProjectHeaderRow: View {
    let node: ProjectNode
    let collapsed: Bool
    let provider: Provider
    /// Its tasks' statuses: a folded project shows them as AiTerm's count chips.
    let statuses: [SessionState]
    let toggle: () -> Void
    let newTask: () -> Void
    let newReview: () -> Void
    let editJiraProjects: () -> Void
    @Environment(\.interfaceScale) private var scale

    /// An empty project has nothing to fold.
    private var collapses: Bool { !node.tasks.isEmpty }

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
                    HeaderTitle(text: node.project.name)
                    if let badge = ProjectJiraBadge.badge(for: node.project) {
                        ProjectJiraBadgeView(badge: badge, canChangeWorkspace: true, editProjects: editJiraProjects)
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
        }
        .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: false))
        .contextMenu {
            newItems
            Divider()
            Button("Jira Projects…", action: editJiraProjects)
        }
    }

    /// What the "+" and the context menu both offer. New Review is greyed only for a folder that is
    /// no repository at all (`.none`); a repository without a remote reads as plain git, and a
    /// review of one of its local branches works — its branch is then left as it was on removal.
    @ViewBuilder private var newItems: some View {
        Button("New Task…", action: newTask)
        Button("New Review…", action: newReview).disabled(provider == .none)
    }
}

/// One task: its agents, its title, its branch, and its status.
struct TaskRowView: View {
    let node: TaskNode
    let selected: Bool
    let agents: [SessionAgent]
    let status: SessionState
    /// Its removal, running or stopped; nil when none.
    var removal: RowRemoval? = nil
    let activate: () -> Void
    var remove: () -> Void = {}
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        SelectableRow(selected: selected, activate: activate) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: Self.marks(agents))
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
                            BranchLabelView(label: BranchLabel(name: node.task.branch, extra: 0, drifted: false, detail: ""))
                                .layoutPriority(1)
                        }
                    }
                }
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: status, size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .accessibilityLabel(node.task.title)
        .accessibilityValue(status.label)
        .contextMenu {
            Button("Remove \(node.task.kindName)…", role: .destructive, action: remove).disabled(removal == .removing)
        }
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
    let activate: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        SelectableRow(selected: selected, activate: activate) {
            HStack(spacing: scale(Space.inset)) {
                AvatarGroupView(group: Self.marks(agents))
                RowTitle(tab.title)
                Spacer(minLength: scale(Space.tight))
                StatusMark(status: status, size: SidebarRowLayout.trailingGlyph(scale))
                    .frame(width: SidebarRowLayout.trailingSlot(scale))
            }
        }
        .padding(.leading, scale(Space.section))
        .accessibilityLabel(tab.title)
        .accessibilityValue(status.label)
    }

    /// AiTerm's terminal row: its agents, or its shell's `>_` when none is known.
    static func marks(_ agents: [SessionAgent]) -> AvatarGroup { AvatarGroup.of(agents.isEmpty ? [.shell] : agents) }
}

/// What the sidebar has to say before its rows: the helper's problem, the last action's failure,
/// what is being done.
struct SidebarBanners: View {
    @ObservedObject var model: SidebarModel

    var body: some View {
        if model.helper.isProblem {
            SidebarBanner(text: model.helper.text, tone: model.helper == .helperUnreachable ? .info : .warning, trailing: Space.block)
        }
        if let error = model.lastError {
            SidebarBanner(text: error, tone: .error)
        }
        if let working = model.working {
            SidebarBanner(text: working, tone: .info)
        }
    }
}

struct SidebarBanner: View {
    enum Tone { case error, warning, info }

    let text: String
    let tone: Tone
    var trailing: CGFloat = Space.base
    var vertical: CGFloat = Space.snug
    @Environment(\.interfaceScale) private var scale

    private var ink: Color {
        switch tone {
        case .error: Palette.text
        case .warning: Palette.amber
        case .info: Palette.muted
        }
    }

    var body: some View {
        Text(text).font(Typography.help).foregroundStyle(ink).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, scale(Space.inset) + scale(Space.base))
            .padding(.trailing, scale(trailing))
            .padding(.vertical, scale(vertical))
    }
}

/// Turns off AppKit's own selection highlight on the sidebar's table, so the row pill is the only
/// painter (AiTerm's `NativeRowHighlight`, without its global swizzle of NSTableView's context-menu
/// highlight, which inside iTerm2 would reach iTerm2's own tables).
struct NativeRowHighlight: NSViewRepresentable {
    static let off = NativeRowHighlight()

    final class Probe: NSView {
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        override func layout() { super.layout(); apply() }

        private weak var found: NSTableView?

        func apply() {
            if let found, found.window != nil, found.window === window {
                found.selectionHighlightStyle = .none
                return
            }
            func table(in view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                return view.subviews.lazy.compactMap { table(in: $0) }.first
            }
            // Up to the sidebar's own host and no further: past it are iTerm2's views and tables.
            var ancestor = superview
            while let current = ancestor {
                if let table = table(in: current) {
                    table.selectionHighlightStyle = .none
                    found = table
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
