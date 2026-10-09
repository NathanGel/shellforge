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
    public static func makeView(model: SidebarModel, chooseFolder: @escaping @MainActor () -> String?, hooks: AgentHooksModel) -> NSView {
        let host = SidebarHostingView(rootView: SidebarView(model: model, chooseFolder: chooseFolder, hooks: hooks))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        // AiTerm is dark-only and forced the whole app dark; here only the sidebar is, so iTerm2's
        // own windows keep the appearance the user chose. Every colour below resolves against this.
        host.appearance = NSAppearance(named: .darkAqua)
        host.autoresizingMask = [.height]
        return host
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
    /// The window the sidebar is drawn in, which the Agent hooks panel hangs from.
    @State private var anchor = WindowAnchor()
    @State private var sheet = PanelSlot()
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            SidebarBanners(model: model)
            List {
                SidebarHeader(addProject: addProject, showHooks: showHooks)
                ForEach(model.rows) { row in rowView(row) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(NativeRowHighlight.off)
        }
        .frame(minWidth: scale(Size.sidebarMinWidth), maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
        .surface(.sidebar)
        .tint(Palette.accent)
        .background(WindowReader(anchor: anchor))
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
