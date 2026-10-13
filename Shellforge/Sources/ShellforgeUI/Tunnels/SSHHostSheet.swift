import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// Names a project's SSH host, from its header's context menu: the host New Task can open in a pane
/// beside the agent. Any concrete `Host` in `~/.ssh/config` will do, with forwards or without; the
/// pane runs `ssh <host>` as the user would.
struct SSHHostSheet: View {
    static let subtitle = "New Task can open ssh to this host in a pane beside the agent."

    let projectName: String
    let loadHosts: () async -> [SSHHost]
    let submit: (String?) -> Void
    let dismiss: @MainActor () -> Void

    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode;
    // these are the storage and accessors the macro would generate.
    private var _hosts = State(initialValue: [SSHHost]())
    private var _current: State<String?>
    private var _loading = State(initialValue: true)
    private var _query = State(initialValue: "")
    private var _open = State(initialValue: false)

    init(projectName: String, current: String?, loadHosts: @escaping () async -> [SSHHost],
         submit: @escaping (String?) -> Void, dismiss: @escaping @MainActor () -> Void) {
        self.projectName = projectName
        self.loadHosts = loadHosts; self.submit = submit; self.dismiss = dismiss
        _current = State(initialValue: current)
    }

    /// A result row's alias column, as the Tunnels sheet's, so the forwards after it start on one line.

    private var hosts: [SSHHost] {
        get { _hosts.wrappedValue }
        nonmutating set { _hosts.wrappedValue = newValue }
    }
    private var current: String? {
        get { _current.wrappedValue }
        nonmutating set { _current.wrappedValue = newValue }
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

    /// Every host whose alias holds `query`, in any case.
    static func offered(hosts: [SSHHost], query: String) -> [SSHHost] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return hosts.filter { needle.isEmpty || $0.alias.range(of: needle, options: .caseInsensitive) != nil }
    }

    static func statusLine(loading: Bool, hosts: [SSHHost], current: String?) -> String? {
        if loading { return "Reading ~/.ssh/config…" }
        if let current, !hosts.contains(where: { $0.alias == current }) { return "\(current) is no longer in ~/.ssh/config." }
        if hosts.isEmpty { return "No hosts in ~/.ssh/config." }
        return nil
    }

    var body: some View {
        SheetLayout(title: "SSH host for \(projectName)", height: Sheet.height, onBackgroundTap: { open = false }) {
            SheetSubtitle(Self.subtitle)
        } content: {
            FormField("SSH host") {
                if let current {
                    PickedItemField(mark: .symbol("terminal"), title: current, monospaced: true, clearHelp: "Clear the host") {
                        self.current = nil
                        open = true
                    }
                } else {
                    SearchPicker(placeholder: "Pick a host from ~/.ssh/config",
                                 query: _query.projectedValue, open: _open.projectedValue,
                                 items: Self.offered(hosts: hosts, query: query), selection: nil,
                                 row: { host in PickerResultRow(mark: .symbol("terminal"), key: host.alias, keyWidth: TunnelSheetLayout.aliasColumnWidth,
                                                                title: host.forwards.map(\.label).joined(separator: ", "), detail: nil) },
                                 selected: { _ in EmptyView() },
                                 onPick: { current = $0.alias; open = false },
                                 toggleHelp: { $0 ? "Hide hosts" : "Show hosts" })
                        .zIndex(1)
                }
                if let line = Self.statusLine(loading: loading, hosts: hosts, current: current) {
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
        submit(current)
        Task { @MainActor in dismiss() }
    }
}
