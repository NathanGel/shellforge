import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Edits a project's tunnels, opened from its header's context menu: each linked `~/.ssh/config`
/// host with its forwarded ports, when it starts by itself, and an ✕ that unlinks it; under them,
/// a search over the config's hosts that forward ports and are not linked yet. Nothing changes until
/// Save hands the whole list up.
///
/// A tunnel is a host alias, never a copy of its forwards: the config stays the one place they are
/// written, and `ssh -N <alias>` applies them as `ssh <alias>` would.
struct TunnelsSheet: View {
    static let subtitle = "Each tunnel runs ssh -N for a host in ~/.ssh/config, with its LocalForward ports."

    let projectName: String
    let loadHosts: () async -> [SSHHost]
    let submit: ([TunnelDefinition]) -> Void
    let dismiss: @MainActor () -> Void

    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode;
    // these are the storage and accessors the macro would generate.
    private var _hosts = State(initialValue: [SSHHost]())
    private var _linked: State<[TunnelDefinition]>
    private var _loading = State(initialValue: true)
    private var _query = State(initialValue: "")
    private var _open = State(initialValue: false)

    init(projectName: String, linked: [TunnelDefinition], loadHosts: @escaping () async -> [SSHHost],
         submit: @escaping ([TunnelDefinition]) -> Void, dismiss: @escaping @MainActor () -> Void) {
        self.projectName = projectName
        self.loadHosts = loadHosts; self.submit = submit; self.dismiss = dismiss
        _linked = State(initialValue: linked)
    }

    /// A result row's alias column, in the mono code face, so the ports after it start on one line.
    /// The auto-start menu beside a linked tunnel: wide enough for "When Shellforge opens".
    private static let autoStartWidth: CGFloat = 190

    private var hosts: [SSHHost] {
        get { _hosts.wrappedValue }
        nonmutating set { _hosts.wrappedValue = newValue }
    }
    private var linked: [TunnelDefinition] {
        get { _linked.wrappedValue }
        nonmutating set { _linked.wrappedValue = newValue }
    }
    private var loading: Bool {
        get { _loading.wrappedValue }
        nonmutating set { _loading.wrappedValue = newValue }
    }
    private var query: String {
        get { _query.wrappedValue }
        nonmutating set { _query.wrappedValue = newValue }
    }
    private var open: Bool {
        get { _open.wrappedValue }
        nonmutating set { _open.wrappedValue = newValue }
    }

    /// The hosts with at least one forward, not linked yet, whose alias holds `query` (any case).
    static func offered(hosts: [SSHHost], linked: [TunnelDefinition], query: String) -> [SSHHost] {
        let taken = Set(linked.map(\.alias))
        let needle = query.trimmingCharacters(in: .whitespaces)
        return hosts.filter { host in
            !host.forwards.isEmpty && !taken.contains(host.alias)
                && (needle.isEmpty || host.alias.range(of: needle, options: .caseInsensitive) != nil)
        }
    }

    /// The line under the field: reading, or that the config offers nothing.
    static func statusLine(loading: Bool, hosts: [SSHHost], linked: [TunnelDefinition]) -> String? {
        if loading { return "Reading ~/.ssh/config…" }
        if !hosts.contains(where: { !$0.forwards.isEmpty }) { return "No hosts in ~/.ssh/config forward ports." }
        if linked.isEmpty { return "Add a host to run its forwards from the sidebar." }
        return nil
    }

    static func autoStartLabel(_ rule: TunnelDefinition.AutoStart) -> String {
        switch rule {
        case .never: "Never"
        case .onLaunch: "When Shellforge opens"
        case .onTaskOpen: "When a task opens"
        }
    }

    var body: some View {
        SheetLayout(title: "Tunnels for \(projectName)", height: Sheet.height, onBackgroundTap: { open = false }) {
            SheetSubtitle(Self.subtitle)
        } content: {
            FormField("Tunnels") {
                ForEach(linked) { linkedTunnel($0) }
                SearchPicker(placeholder: "Add a host from ~/.ssh/config",
                             query: _query.projectedValue, open: _open.projectedValue,
                             items: Self.offered(hosts: hosts, linked: linked, query: query), selection: nil,
                             row: hostRow,
                             selected: { _ in EmptyView() },
                             onPick: { linked.append(TunnelDefinition(alias: $0.alias)) },
                             toggleHelp: { $0 ? "Hide hosts" : "Show hosts" })
                    // Over the status line after it, as AiTerm's FormField orders its content front to back.
                    .zIndex(1)
                if let line = Self.statusLine(loading: loading, hosts: hosts, linked: linked) {
                    HelpText(line)
                }
            }
        } footer: {
            SheetFooter(primary: "Save", closeList: closeList,
                        cancel: { Task { @MainActor in dismiss() } }, submit: confirm)
        }
        .task {
            hosts = await loadHosts()
            loading = false
        }
    }

    private func closeList() -> Bool {
        guard open else { return false }
        open = false
        return true
    }

    private func confirm() {
        submit(linked)
        Task { @MainActor in dismiss() }
    }

    private func forwards(of alias: String) -> String {
        hosts.first { $0.alias == alias }?.forwards.map(\.label).joined(separator: ", ") ?? ""
    }

    private func hostRow(_ host: SSHHost) -> some View {
        PickerResultRow(mark: .symbol("network"), key: host.alias, keyWidth: TunnelSheetLayout.aliasColumnWidth,
                        title: host.forwards.map(\.label).joined(separator: ", "), detail: nil)
    }

    private func linkedTunnel(_ tunnel: TunnelDefinition) -> some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            linkedTunnelLine(tunnel)
            Toggle("Keep running after Shellforge quits", isOn: Binding(get: { tunnel.keepRunning }, set: { kept in
                if let i = linked.firstIndex(where: { $0.alias == tunnel.alias }) { linked[i].keepRunning = kept }
            }))
            .toggleStyle(.checkbox).font(Typography.body)
        }
    }

    private func linkedTunnelLine(_ tunnel: TunnelDefinition) -> some View {
        HStack(spacing: Space.base) {
            PickedItemField(mark: .symbol("network"), key: tunnel.alias, title: forwards(of: tunnel.alias),
                            clearHelp: "Remove \(tunnel.alias)") {
                linked.removeAll { $0.alias == tunnel.alias }
            }
            Select(values: TunnelDefinition.AutoStart.allCases,
                   selection: Binding(get: { tunnel.autoStart }, set: { rule in
                       if let i = linked.firstIndex(where: { $0.alias == tunnel.alias }) { linked[i].autoStart = rule }
                   }),
                   label: Self.autoStartLabel)
                .frame(width: Self.autoStartWidth)
        }
    }
}
