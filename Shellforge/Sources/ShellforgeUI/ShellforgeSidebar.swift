import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// The sidebar on the left of a Shellforge window: projects → tasks → tabs.
@MainActor
public enum ShellforgeSidebar {
    /// Its width in points. The window's layout gives the session area what is left.
    public static let width: CGFloat = Size.sidebarWidth

    /// The view the window places at its left edge: as wide as the sidebar, and only its height
    /// follows the window's. `chooseFolder` asks the user for a project folder (an open panel);
    /// `hooks` is the app's Agent hooks sheet.
    /// `machine` is the app's one sampler of the Mac's readings, for the footer.
    /// `backpack` is the app's one Backpack Mode; `showBackpack` hands back how this sidebar opens
    /// its sheet, for the View menu's ⌘B.
    public static func makeView(model: SidebarModel, chooseFolder: @escaping @MainActor () -> String?, hooks: AgentHooksModel,
                                machine: MachineMonitor, backpack: BackpackController,
                                showBackpack: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { _ in }) -> NSView {
        let host = SidebarHostingView(rootView: SidebarView(model: model, chooseFolder: chooseFolder, hooks: hooks, machine: machine,
                                                            backpack: backpack, showBackpack: showBackpack))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        // AiTerm is dark-only and forced the whole app dark; here only the sidebar is, so iTerm2's
        // own windows keep the appearance the user chose. Every colour below resolves against this.
        host.appearance = NSAppearance(named: .darkAqua)
        host.autoresizingMask = [.height]
        return host
    }
}

// FooterClock and SidebarFooterHost: ported from AiTerm (app/Sources/AiTerm/Views/SidebarView.swift), GPLv3, Laurens D'Hondt.

/// The instant and calendar the usage footer reads its reset times against. Unset, the footer uses
/// the wall clock and the user's calendar; a test pins both so the labels it draws do not move with
/// the time of day, the weekday or the machine's time zone. (AiTerm's `FooterClock`.)
struct FooterClock {
    var now: Date
    var calendar: Calendar
}

private struct FooterClockKey: EnvironmentKey { static let defaultValue: FooterClock? = nil }

extension EnvironmentValues {
    var footerClock: FooterClock? {
        get { self[FooterClockKey.self] }
        set { self[FooterClockKey.self] = newValue }
    }
}

/// AiTerm's `SidebarFooterHost`: the vendor rows recomputed on the minute — a window that has reset
/// is dropped, and a reset time gains its weekday across midnight — and the selected row's context
/// and the Mac's readings over them.
struct SidebarFooterHost: View {
    @ObservedObject var model: SidebarModel
    @ObservedObject var hooks: AgentHooksModel
    @ObservedObject var machine: MachineMonitor
    @ObservedObject var backpack: BackpackController
    let toggleMac: () -> Void
    let openMacSettings: () -> Void
    @Environment(\.footerClock) private var footerClock

    var body: some View {
        TimelineView(.everyMinute) { context in
            SidebarFooter(task: model.footerRow,
                          rows: model.vendorRows(now: footerClock?.now ?? context.date, calendar: footerClock?.calendar ?? .current,
                                                 claudeStatusLineInstalled: hooks.claudeStatusLineInstalled),
                          machine: machine.lines,
                          mac: MacModePresentation.line(mode: MacMode(state: backpack.state, transition: backpack.transition),
                                                        hotspot: backpack.network, wifi: backpack.currentNetwork),
                          toggleMac: toggleMac, openMacSettings: openMacSettings)
        }
    }
}

/// The sidebar's host: where `NativeRowHighlight` stops looking for its list.
final class SidebarHostingView<Content: View>: NSHostingView<Content>, RowHighlightBoundary {}

/// AiTerm's sidebar, inside iTerm2's window: the PROJECTS header, each project with its tasks and
/// the selected task's tabs, the tabs of no task, the banners, or the empty state.
struct SidebarView: View {
    @ObservedObject var model: SidebarModel
    let chooseFolder: @MainActor () -> String?
    @ObservedObject var hooks: AgentHooksModel
    let machine: MachineMonitor
    let backpack: BackpackController
    let showBackpack: @MainActor (@escaping @MainActor () -> Void) -> Void
    /// The window the sidebar is drawn in, which the Agent hooks panel hangs from.
    @State private var anchor = WindowAnchor()
    @State private var sheet = PanelSlot()
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            SidebarBanners(model: model)
            List {
                SidebarHeader(addProject: addProject, showHooks: showHooks, showMacSettings: showMacSettings)
                ForEach(model.rows) { row in rowView(row) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(NativeRowHighlight.off)
            SidebarFooterHost(model: model, hooks: hooks, machine: machine, backpack: backpack,
                              toggleMac: { BackpackToggle(backpack: backpack, presentSheet: presentBackpack).run() },
                              openMacSettings: showMacSettings)
        }
        .frame(minWidth: scale(Size.sidebarMinWidth), maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
        .surface(.sidebar)
        .tint(Palette.accent)
        .background(WindowReader(anchor: anchor))
        // The View menu's ⌘B opens the sheet on the key window's sidebar: this one says how.
        .onAppear { showBackpack(presentBackpack) }
    }

    @ViewBuilder private func rowView(_ row: SidebarRow) -> some View {
        switch row {
        case .empty:
            SidebarEmptyState(canAdd: true, add: addProject).listRowSeparator(.hidden)
        case .project(let node, let collapsed):
            ProjectHeaderRow(node: node, collapsed: collapsed, provider: model.providers[node.id] ?? .git,
                             statuses: node.tasks.map { model.status(ofTask: $0.id) },
                             toggle: { model.toggleCollapsed(node.id) },
                             newTask: { showNewTask(in: node.id) })
                .listRowSeparator(.hidden)
        case .task(let node, let selected):
            TaskRowView(node: node, selected: selected, agents: model.avatars(forTask: node.id),
                        status: model.status(ofTask: node.id), activate: { model.select(task: node.id) })
                .listRowSeparator(.hidden)
        case .tab(let tab, let selected):
            TabRowView(tab: tab, selected: selected, agents: model.avatars(forTab: tab.id),
                       status: model.status(ofTab: tab.id), activate: { model.select(tab: tab.id) })
                .listRowSeparator(.hidden)
        case .otherTabsHeading:
            SidebarHeading("Other tabs")
                .frame(height: scale(Size.menuRow)).padding(.leading, scale(Space.base))
                .listRowSeparator(.hidden)
        }
    }

    /// AiTerm's Backpack sheet, in the sidebar's one panel.
    private func presentBackpack() {
        sheet.present(over: anchor.window) { dismiss in BackpackSheet(model: BackpackSheetModel(backpack: backpack), dismiss: dismiss) }
    }

    /// The Mac card — what Backpack Mode needs from this Mac — in a panel of its own with Done, until
    /// Shellforge has a Settings window to hold it (AiTerm's Settings › Integrations › Mac).
    private func showMacSettings() {
        let integrations = IntegrationSettingsModel(jira: JiraSettings.load())
        sheet.present(over: anchor.window) { dismiss in SettingsPanel(backpack: backpack, integrations: integrations, close: dismiss) }
    }

    /// The Agent hooks sheet, in its own dark panel on the sidebar's window.
    private func showHooks() {
        sheet.present(over: anchor.window) { dismiss in AgentHooksView(model: hooks, dismiss: dismiss) }
    }

    private func addProject() {
        if let folder = chooseFolder() { Task { await model.addProject(folder: folder) } }
    }

    /// AiTerm's New Task sheet, in its own dark panel on the sidebar's window; one at a time.
    private func showNewTask(in project: UUID) {
        guard let newTask = model.makeNewTaskModel(for: project) else { return }
        sheet.present(over: anchor.window) { dismiss in NewTaskSheet(model: newTask, dismiss: dismiss) }
    }
}
