import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The SSH panel: each project that names hosts — its SSH host and its tunnels — under its own
/// header, then the config's other hosts. A host of the config connects in a tab of its own; a
/// tunnel has its row as in Sessions, to start and stop it. Per window, over that window's model.
/// `titled` false when the title is pinned above the panel instead.
struct SSHPanel: View {
    @ObservedObject var model: SidebarModel
    /// The model's workspace, watched so a project's hosts redraw the moment they change.
    @ObservedObject var document: WorkspaceDocument
    let titled: Bool
    var providers: [UUID: Provider] = [:]
    /// A project's Tunnels and SSH Host sheets, as Sessions' project menu opens them.
    let showTunnels: (UUID) -> Void
    let showSSHHost: (UUID) -> Void
    /// Opens the Add Host sheet; nil greys the button.
    var addHost: (() -> Void)? = nil
    @Environment(\.interfaceScale) private var scale

    /// The panel's `ViewMark`.
    static let markName = "SSHPanel"
    static let emptyText = "No hosts in ~/.ssh/config yet."
    static let missingText = "Not in ~/.ssh/config"
    static let addHostTitle = "Add Host…"
    static let tunnelsTitle = "Tunnels…"
    static let connectTitle = "Connect"
    static let startTitle = "Start"
    static let stopTitle = "Stop"
    static let answerTitle = "Answer in Tab"

    /// A row's `ViewMark`, for tests: its section's id and its alias.
    nonisolated static func rowMark(section: String, alias: String) -> String { "SSHRow:\(section):\(alias)" }

    /// The panel's sections over `model`'s projects and the config as last read.
    static func sections(_ model: SidebarModel) -> [SSHPanelSection] {
        SSHPanelLayout.sections(projects: model.document.workspace.projects, hosts: model.sshHosts.map { Array($0.values) })
    }

    /// The empty state shows once the config has been read and there is nothing to list.
    static func showsEmptyState(_ sections: [SSHPanelSection], loaded: Bool) -> Bool { loaded && sections.isEmpty }

    /// What VoiceOver calls a host's row: its alias, then its tunnel's state, or “host”.
    static func accessibilityLabel(_ entry: SSHPanelEntry, tunnel: TunnelRowItem?) -> String {
        "\(entry.alias), \(tunnel?.state.rawValue ?? "host")"
    }

    /// The actions a host's row offers VoiceOver, in order: Connect while the config has it, then
    /// its tunnel's Start or Stop and Answer in Tab, as the tunnel's row offers them.
    static func accessibilityActions(_ entry: SSHPanelEntry, tunnel: TunnelRowItem?) -> [String] {
        var actions = entry.inConfig ? [connectTitle] : []
        if let tunnel {
            let look = TunnelRowView.look(tunnel)
            if let action = look.action { actions.append(action == .start ? startTitle : stopTitle) }
            if look.answersInTab { actions.append(answerTitle) }
        }
        return actions
    }

    var body: some View {
        let sections = Self.sections(model)
        VStack(alignment: .leading, spacing: 0) {
            if titled { PanelTitle(panel: .ssh) { SSHAddHostButton(action: addHost) } }
            if Self.showsEmptyState(sections, loaded: model.sshHosts != nil) {
                SSHEmptyState(addHost: addHost)
            } else {
                List {
                    ForEach(sections) { section in
                        header(section).listRowSeparator(.hidden)
                        ForEach(section.entries) { entry in
                            hostRow(entry, in: section).listRowSeparator(.hidden)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(NativeRowHighlight.off)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ViewMark(name: Self.markName))
    }

    @ViewBuilder private func header(_ section: SSHPanelSection) -> some View {
        switch section.kind {
        case .project(let id):
            SSHProjectHeader(title: section.title, provider: providers[id] ?? .git,
                             sshHostTitle: SidebarModel.sshHostMenuTitle(model.project(id)?.sshHost),
                             showTunnels: { showTunnels(id) }, showSSHHost: { showSSHHost(id) })
        case .other:
            SSHOtherHeader(title: section.title)
        }
    }

    private func hostRow(_ entry: SSHPanelEntry, in section: SSHPanelSection) -> some View {
        let projectId: UUID? = if case .project(let id) = section.kind { id } else { nil }
        let tunnel = entry.isTunnel ? projectId.flatMap { id in model.tunnelRows(of: id).first { $0.alias == entry.alias } } : nil
        return SSHHostRow(entry: entry, tunnel: tunnel, projectId: projectId, model: model)
            .background(ViewMark(name: Self.rowMark(section: section.id, alias: entry.alias)))
    }
}

/// The header's Add Host button, greyed until there is a sheet to open.
struct SSHAddHostButton: View {
    let action: (() -> Void)?
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    var body: some View {
        Button(action: { action?() }) {
            Image(systemName: "plus").font(Typography.label).foregroundStyle(surface.secondaryInk)
        }
        .buttonStyle(.plain)
        .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
        .disabled(action == nil)
        .help(SSHPanel.addHostTitle)
        .accessibilityLabel(SSHPanel.addHostTitle)
    }
}

/// No host anywhere: the config has none and no project names one.
private struct SSHEmptyState: View {
    let addHost: (() -> Void)?
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale(Space.inset)) {
            RowCaption(SSHPanel.emptyText)
            Button(SSHPanel.addHostTitle) { addHost?() }.disabled(addHost == nil)
        }
        .padding(.horizontal, SidebarRowLayout.listInset + scale(Space.base))
        .padding(.top, scale(Space.inset))
    }
}

/// A project's header: its provider mark and its name; its menu opens the project's Tunnels and
/// SSH Host sheets.
private struct SSHProjectHeader: View {
    let title: String
    let provider: Provider
    let sshHostTitle: String
    let showTunnels: () -> Void
    let showSSHHost: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            ProviderIcon(provider: provider)
            HeaderTitle(text: title)
            Spacer(minLength: scale(Space.tight))
        }
        .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), project")
        .accessibilityAction(named: Text(SSHPanel.tunnelsTitle), showTunnels)
        .accessibilityAction(named: Text(sshHostTitle), showSSHHost)
        .contextMenu {
            Button(SSHPanel.tunnelsTitle, action: showTunnels)
            Button(sshHostTitle, action: showSSHHost)
        }
    }
}

/// The config's hosts no project names, under “Other hosts”.
private struct SSHOtherHeader: View {
    let title: String
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack { HeaderTitle(text: title); Spacer(minLength: 0) }
            .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A host: its alias, dimmed with “Not in ~/.ssh/config” when the config no longer has it, and
/// Connect while it does; a tunnel's row under it, to start and stop it. One element to VoiceOver,
/// with Connect, Start and Stop as its actions.
private struct SSHHostRow: View {
    let entry: SSHPanelEntry
    let tunnel: TunnelRowItem?
    let projectId: UUID?
    let model: SidebarModel
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    private func connect() { Task { await model.connect(alias: entry.alias, in: projectId) } }
    private func start() { model.startTunnel(entry.alias) }
    private func stop() { model.stopTunnel(entry.alias) }
    private func answerInTab() { if let projectId { model.answerInTab(entry.alias, in: projectId) } }

    /// The row's actions that can run now; nil for one that cannot.
    private var connectAction: (() -> Void)? { entry.inConfig ? { connect() } : nil }
    private var startAction: (() -> Void)? { look?.action == .start ? { start() } : nil }
    private var stopAction: (() -> Void)? { look?.action == .stop ? { stop() } : nil }
    private var answerAction: (() -> Void)? { look?.answersInTab == true ? { answerInTab() } : nil }
    private var look: TunnelRowView.Look? { tunnel.map { TunnelRowView.look($0) } }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SSHPanel.accessibilityLabel(entry, tunnel: tunnel))
            .accessibilityValue(entry.inConfig ? "" : "Not in SSH config")
            .modifier(SSHRowAction(title: SSHPanel.connectTitle, run: connectAction))
            .modifier(SSHRowAction(title: SSHPanel.startTitle, run: startAction))
            .modifier(SSHRowAction(title: SSHPanel.stopTitle, run: stopAction))
            .modifier(SSHRowAction(title: SSHPanel.answerTitle, run: answerAction))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: scale(Space.inset)) {
                Image(systemName: ActivityPanel.ssh.symbol).font(Typography.micro).foregroundStyle(surface.secondaryInk)
                    .frame(width: scale(Size.avatar))
                RowTitle(entry.alias, dimmed: !entry.inConfig)
                Spacer(minLength: scale(Space.tight))
                if entry.inConfig {
                    Button(action: connect) {
                        Image(systemName: "terminal").font(Typography.micro).foregroundStyle(surface.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
                    .help("\(SSHPanel.connectTitle): ssh \(entry.alias) in a new tab")
                }
            }
            .frame(minHeight: scale(Size.menuRow))
            .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
            // A tunnel's own row says it is missing, as in Sessions.
            if !entry.inConfig && tunnel == nil {
                RowCaption(SSHPanel.missingText).lineLimit(1)
                    .padding(.leading, scale(Space.base) + scale(Size.avatar) + scale(Space.inset))
            }
            if let tunnel {
                TunnelRowView(row: tunnel, start: start, stop: stop, answerInTab: answerInTab, canRearrange: false)
            }
        }
    }
}

/// A named VoiceOver action that is there only when it can run: an action cannot be greyed.
private struct SSHRowAction: ViewModifier {
    let title: String
    let run: (() -> Void)?

    func body(content: Content) -> some View {
        if let run { content.accessibilityAction(named: Text(title), run) } else { content }
    }
}
