import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The SSH panel: each project that names hosts — its SSH host and its tunnels — under its own
/// header, then the config's other hosts. One row per host: a dot, its alias, a tunnel's Start or
/// Stop, and Open in Terminal; under it, this window's tabs opened for it. Nothing opens or starts
/// but a click on a button. Per window, over that window's model. `titled` false when the title is
/// pinned above the panel instead.
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
    static let openInTerminalTitle = "Open in Terminal"
    static let startTitle = "Start"
    static let stopTitle = "Stop"
    static let answerTitle = "Answer in Tab"
    static let showTitle = PanelTabLine.showTitle

    /// Open in Terminal's tooltip.
    static func openInTerminalHelp(_ alias: String) -> String { "\(openInTerminalTitle): ssh \(alias) in a new tab" }

    /// A row's `ViewMark`, for tests: its section's id and its alias.
    nonisolated static func rowMark(section: String, alias: String) -> String { "SSHRow:\(section):\(alias)" }

    /// An open session's line under its host, for tests: its section, its host and its tab.
    nonisolated static func sessionMark(section: String, alias: String, tab: String) -> String { "SSHSession:\(section):\(alias):\(tab)" }

    /// The panel's sections over `model`'s projects and the config as last read.
    static func sections(_ model: SidebarModel) -> [SSHPanelSection] {
        SSHPanelLayout.sections(projects: model.document.workspace.projects, hosts: model.sshHosts.map { Array($0.values) })
    }

    /// The tabs of this window opened for `alias`, in tab order: the lines under its row.
    static func sessions(_ model: SidebarModel, alias: String) -> [TabSnapshot] { model.panelTabs(for: .ssh(alias: alias)) }

    /// The empty state shows once the config has been read and there is nothing to list.
    static func showsEmptyState(_ sections: [SSHPanelSection], loaded: Bool) -> Bool { loaded && sections.isEmpty }

    /// A host row's buttons.
    enum HostButton: Equatable { case answerInTab, start, stop, openInTerminal }

    /// A host row's buttons, in order: a tunnel's Answer in Tab and Start or Stop as its row in
    /// Sessions shows them, then Open in Terminal while the config has the host.
    static func buttons(_ entry: SSHPanelEntry, tunnel: TunnelRowItem?) -> [HostButton] {
        var buttons: [HostButton] = []
        if let tunnel {
            let look = TunnelRowView.look(tunnel)
            if look.answersInTab { buttons.append(.answerInTab) }
            if let action = look.action { buttons.append(action == .start ? .start : .stop) }
        }
        if entry.inConfig { buttons.append(.openInTerminal) }
        return buttons
    }

    static func title(_ button: HostButton) -> String {
        switch button {
        case .answerInTab: answerTitle
        case .start: startTitle
        case .stop: stopTitle
        case .openInTerminal: openInTerminalTitle
        }
    }

    /// What VoiceOver calls a host's row: its alias, then its tunnel's state, or “host”.
    static func accessibilityLabel(_ entry: SSHPanelEntry, tunnel: TunnelRowItem?) -> String {
        "\(entry.alias), \(tunnel?.state.rawValue ?? "host")"
    }

    /// The actions a host's row offers VoiceOver: its buttons'.
    static func accessibilityActions(_ entry: SSHPanelEntry, tunnel: TunnelRowItem?) -> [String] {
        buttons(entry, tunnel: tunnel).map(title)
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
                            ForEach(Self.sessions(model, alias: entry.alias)) { tab in
                                sessionRow(tab, of: entry, in: section).listRowSeparator(.hidden)
                            }
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
        let open = !Self.sessions(model, alias: entry.alias).isEmpty
        return SSHHostRow(entry: entry, tunnel: tunnel, projectId: projectId, hasSession: open, model: model)
            .background(ViewMark(name: Self.rowMark(section: section.id, alias: entry.alias)))
    }

    private func sessionRow(_ tab: TabSnapshot, of entry: SSHPanelEntry, in section: SSHPanelSection) -> some View {
        PanelTabLine(tab: tab, indent: scale(Space.section) + scale(Size.avatar), model: model)
            .background(ViewMark(name: Self.sessionMark(section: section.id, alias: entry.alias, tab: tab.id)))
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
        .accessibilityAddTraits(.isHeader)
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

/// A host, on one line: a dot — its tunnel's state, or whether a tab of it is open — its alias,
/// dimmed with “Not in ~/.ssh/config” when the config no longer has it, then its buttons. A
/// tunnel's ports, error and uptime as its row in Sessions shows them. Clicking the row itself does
/// nothing. One element to VoiceOver, with its buttons as its actions.
private struct SSHHostRow: View {
    let entry: SSHPanelEntry
    let tunnel: TunnelRowItem?
    let projectId: UUID?
    /// A tab of this window is open on the host.
    let hasSession: Bool
    let model: SidebarModel
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    private func openInTerminal() { Task { await model.connect(alias: entry.alias, in: projectId) } }
    private func start() { model.startTunnel(entry.alias) }
    private func stop() { model.stopTunnel(entry.alias) }
    private func answerInTab() { if let projectId { model.answerInTab(entry.alias, in: projectId) } }

    private var look: TunnelRowView.Look? { tunnel.map { TunnelRowView.look($0) } }
    private var buttons: [SSHPanel.HostButton] { SSHPanel.buttons(entry, tunnel: tunnel) }
    private var captionInset: CGFloat { scale(Size.avatar) + scale(Space.inset) }

    private func run(_ button: SSHPanel.HostButton) {
        switch button {
        case .answerInTab: answerInTab()
        case .start: start()
        case .stop: stop()
        case .openInTerminal: openInTerminal()
        }
    }

    private var dotColor: Color {
        if let look { return TunnelRowView.color(look.tone) }
        return hasSession ? Palette.green : Palette.muted
    }

    private func symbol(_ button: SSHPanel.HostButton) -> String {
        switch button {
        case .answerInTab, .openInTerminal: "terminal"
        case .start: "play.fill"
        case .stop: "stop.fill"
        }
    }

    private func help(_ button: SSHPanel.HostButton) -> String {
        switch button {
        case .answerInTab: "Answer in Tab: ssh needs an answer"
        case .start: "Start \(entry.alias)"
        case .stop: "Stop \(entry.alias)"
        case .openInTerminal: SSHPanel.openInTerminalHelp(entry.alias)
        }
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SSHPanel.accessibilityLabel(entry, tunnel: tunnel))
            .accessibilityValue(entry.inConfig ? "" : "Not in SSH config")
            .modifier(SSHRowAction(button: .answerInTab, offered: buttons, run: answerInTab))
            .modifier(SSHRowAction(button: .start, offered: buttons, run: start))
            .modifier(SSHRowAction(button: .stop, offered: buttons, run: stop))
            .modifier(SSHRowAction(button: .openInTerminal, offered: buttons, run: openInTerminal))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: scale(Space.tight)) {
            HStack(spacing: scale(Space.inset)) {
                ToneDot(color: dotColor, size: scale(Size.statusMarkSmall)).frame(width: scale(Size.avatar))
                RowTitle(entry.alias, dimmed: !entry.inConfig || tunnel?.missing == true)
                if let tunnel, !tunnel.ports.isEmpty {
                    Text(tunnel.ports).font(Typography.monoCode).foregroundStyle(surface.secondaryInk).lineLimit(1)
                        .help(TunnelRowView.portsHelp(tunnel) ?? "")
                }
                if tunnel?.keepRunning == true {
                    Image(systemName: "pin.fill").font(Typography.micro).foregroundStyle(surface.secondaryInk)
                        .help("Keeps running after Shellforge quits")
                }
                Spacer(minLength: scale(Space.tight))
                ForEach(buttons, id: \.self) { button in
                    Button(action: { run(button) }) {
                        Image(systemName: symbol(button)).font(Typography.micro).foregroundStyle(surface.secondaryInk)
                    }
                    .buttonStyle(.plain)
                    .frame(width: SidebarRowLayout.trailingSlot(scale), height: SidebarRowLayout.trailingSlot(scale))
                    .help(help(button))
                }
            }
            if let caption = look?.caption {
                RowCaption(caption, warns: true).lineLimit(2).padding(.leading, captionInset)
            } else if !entry.inConfig {
                RowCaption(SSHPanel.missingText).lineLimit(1).padding(.leading, captionInset)
            }
            if let tunnel {
                // Re-drawn each minute, for the uptime.
                TimelineView(.everyMinute) { context in
                    if let detail = TunnelRowView.detail(tunnel, now: context.date) {
                        RowCaption(detail).lineLimit(1).padding(.leading, captionInset)
                    }
                }
            }
        }
        .frame(minHeight: scale(Size.menuRow))
        .padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
    }
}

/// A named VoiceOver action that is there only while its button is: an action cannot be greyed.
private struct SSHRowAction: ViewModifier {
    let button: SSHPanel.HostButton
    let offered: [SSHPanel.HostButton]
    let run: () -> Void

    func body(content: Content) -> some View {
        if offered.contains(button) { content.accessibilityAction(named: Text(SSHPanel.title(button)), run) } else { content }
    }
}
