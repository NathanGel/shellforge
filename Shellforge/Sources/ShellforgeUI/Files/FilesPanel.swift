import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// What is at a row's path on disk when the row is activated: what git or the listing said may be
/// out of date by then.
public enum FileKind: Sendable, Equatable {
    case file, folder, gone

    /// Reads the disk: call it off the main actor.
    public static func onDisk(_ path: String) -> FileKind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .gone }
        return isDirectory.boolValue ? .folder : .file
    }
}

/// Opens a file of the Files panel in a terminal tab: a new tab in the project's folder, titled
/// with the file's name, running `EditorCommand.command`, tagged with the file so the panel lists it. The editor is resolved at the click — the
/// Settings choice, else `$EDITOR`, else `vi` — and the login environment is read off the main
/// actor, as it may run a login shell when it has not been read yet.
@MainActor
struct FileOpener {
    let host: TerminalHost
    /// The app's own suite, where Settings › Core › Terminal editor is saved.
    let defaults: UserDefaults
    let environment: @Sendable () -> [String: String]
    var kind: @Sendable (String) -> FileKind = FileKind.onDisk

    /// A file still there opens in its editor, unless its name has a control character: then nothing
    /// opens and the section says why. One gone since the listing opens nothing: the project is
    /// listed again. A folder never opens an editor: it folds or unfolds instead.
    func open(_ node: FileNode, in project: Project, files: FilesModel) async {
        let path = URL(fileURLWithPath: project.path).appendingPathComponent(node.path).path
        let (kind, environment) = (self.kind, self.environment)
        let (found, variables) = await BackgroundWork.run { () -> (FileKind, [String: String]) in
            let found = kind(path)
            return (found, found == .file ? environment() : [:])
        }
        switch found {
        case .gone:
            await files.refresh(project: project.id)
        case .folder:
            files.toggleFolder(project: project.id, folder: node)
            await files.refresh(project: project.id)
        case .file:
            let editor = EditorCommand.editor(setting: defaults.string(forKey: EditorCommand.settingKey), environment: variables)
            let command: FileCommand
            do {
                command = try EditorCommand.command(editor: editor, file: node.path)
            } catch {
                files.report(error.localizedDescription, project: project.id)
                return
            }
            files.report(nil, project: project.id)
            host.openTab(in: project.path, title: node.name, running: command, panel: .file(project: project.id, path: node.path))
        }
    }
}

extension FilesModel {
    /// Folds or unfolds a folder; one opened that was never loaded (outside a repository) is read.
    func toggleFolder(project: UUID, folder: FileNode) {
        let opening = !isOpen(project: project, folder: folder.path)
        toggle(project: project, folder: folder.path)
        guard opening, folder.isFolder, folder.children == nil else { return }
        Task { await loadChildren(project: project, folder: folder.path) }
    }
}

/// The Files panel: one section per workspace project, in the workspace's order — the project's
/// row (its provider mark, a chevron, its name) folds it — then its tree. Only open folders'
/// children are made into rows. Under a file's row, this window's editor tabs of it. `titled`
/// false when the title is pinned above the panel instead.
struct FilesPanel: View {
    @ObservedObject var model: FilesModel
    /// This window's model, for its tabs: the Files model is the app's, the tabs are the window's.
    @ObservedObject var sidebar: SidebarModel
    let titled: Bool
    var providers: [UUID: Provider] = [:]
    let opener: FileOpener
    @Environment(\.interfaceScale) private var scale

    /// The panel's `ViewMark`.
    static let markName = "FilesPanel"

    /// A row's `ViewMark`, for tests: the project's id and the row's path ("" for the project's row).
    nonisolated static func rowMark(project: UUID, path: String) -> String { "FilesRow:\(project.uuidString):\(path)" }

    /// A tab's line, for tests: the row it is listed under and the tab.
    nonisolated static func tabMark(row: String, tab: String) -> String { "FilesTab:\(row):\(tab)" }

    /// One line of the panel.
    enum Row: Identifiable, Equatable {
        case project(Project, open: Bool)
        /// What the section says in place of its tree: loading, its folder gone, why it can't be read.
        case message(project: UUID, text: String, warns: Bool)
        /// Why the last file opened opened nothing.
        case problem(project: UUID, text: String)
        case node(Project, FileNode, depth: Int, open: Bool)
        /// Under an open folder with nothing listed in it, at its children's depth: what it is.
        case note(project: UUID, folder: String, text: String, depth: Int)

        var id: String {
            switch self {
            case .project(let project, _): FilesPanel.rowMark(project: project.id, path: "")
            case .message(let project, _, _): "message:" + project.uuidString
            case .problem(let project, _): "problem:" + project.uuidString
            case .node(let project, let node, _, _): FilesPanel.rowMark(project: project.id, path: node.path)
            case .note(let project, let folder, _, _): "note:\(project.uuidString):\(folder)"
            }
        }
    }

    static let loadingText = "Loading…"
    static let missingText = "Folder not found"
    static let emptyText = "No files"
    static let emptyFolderText = "Empty folder"
    static let submoduleText = "Submodule"
    static let repositoryText = "Repository"

    /// The rows drawn: a closed section or folder contributes no rows below its own.
    static func rows(_ sections: [FilesSection], isOpen: (UUID, String) -> Bool) -> [Row] {
        sections.flatMap { section -> [Row] in
            let project = section.project
            let open = isOpen(project.id, "")
            var rows: [Row] = [.project(project, open: open)]
            guard open else { return rows }
            if let problem = section.problem { rows.append(.problem(project: project.id, text: problem)) }
            switch section.state {
            case .loading: rows.append(.message(project: project.id, text: loadingText, warns: false))
            case .missing: rows.append(.message(project: project.id, text: missingText, warns: true))
            case .unreadable(let reason): rows.append(.message(project: project.id, text: reason, warns: true))
            case .tree(let nodes) where nodes.isEmpty: rows.append(.message(project: project.id, text: emptyText, warns: false))
            case .tree(let nodes): rows += treeRows(nodes, project: project, depth: 0, isOpen: isOpen)
            }
            return rows
        }
    }

    /// Where each editor tab is listed, by the id of the row it goes under: its file's row while
    /// that row is drawn, else its project's row — the file's folder is closed, or the file is no
    /// longer listed — so every tab stays in reach. A tab of a project the panel doesn't list is
    /// left out: Sessions lists it under Other Tabs once its project is gone. In tab order.
    static func tabLines(_ rows: [Row], tabs: [TabSnapshot]) -> [String: [TabSnapshot]] {
        let drawn = Set(rows.map(\.id))
        var lines: [String: [TabSnapshot]] = [:]
        for tab in tabs {
            guard case .file(let project, let path) = tab.panel else { continue }
            let file = rowMark(project: project, path: path)
            let header = rowMark(project: project, path: "")
            guard let row = drawn.contains(file) ? file : drawn.contains(header) ? header : nil else { continue }
            lines[row, default: []].append(tab)
        }
        return lines
    }

    /// How far a tab's line under `row` is indented: one step past the file's row. Past
    /// `SelectableRow`'s own padding, which already holds the inset's `Space.base`.
    private func tabIndent(_ row: Row) -> CGFloat {
        let depth = if case .node(_, _, let fileDepth, _) = row { fileDepth + 1 } else { 0 }
        return max(0, FileRow.leadingInset(depth: depth, scale) - scale(Space.base))
    }

    private static func treeRows(_ nodes: [FileNode], project: Project, depth: Int, isOpen: (UUID, String) -> Bool) -> [Row] {
        nodes.flatMap { node -> [Row] in
            let open = node.isFolder && isOpen(project.id, node.path)
            let row = Row.node(project, node, depth: depth, open: open)
            guard open, let children = node.children else { return [row] }
            if children.isEmpty {
                // Not a folder still loading: say what it is.
                let text = switch node.nested {
                case .submodule: submoduleText
                case .repository: repositoryText
                case nil: emptyFolderText
                }
                return [row, .note(project: project.id, folder: node.path, text: text, depth: depth + 1)]
            }
            return [row] + treeRows(children, project: project, depth: depth + 1, isOpen: isOpen)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if titled { PanelTitle(panel: .files) }
            let rows = Self.rows(model.sections, isOpen: model.isOpen)
            let lines = Self.tabLines(rows, tabs: sidebar.tree.panelTabs)
            List {
                ForEach(rows) { row in
                    rowView(row).listRowSeparator(.hidden)
                    ForEach(lines[row.id] ?? []) { tab in
                        PanelTabLine(tab: tab, indent: tabIndent(row), model: sidebar)
                            .background(ViewMark(name: Self.tabMark(row: row.id, tab: tab.id)))
                            .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(NativeRowHighlight.off)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ViewMark(name: Self.markName))
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .project(let project, let open):
            FilesProjectRow(project: project, open: open, provider: providers[project.id] ?? .git,
                            toggle: { model.toggle(project: project.id, folder: "") })
                .background(ViewMark(name: row.id))
        case .message(_, let text, let warns):
            RowCaption(text, warns: warns)
                .frame(maxWidth: .infinity, minHeight: scale(Size.menuRow), alignment: .leading)
                .padding(.leading, scale(Space.section) + SidebarRowLayout.chevronWidth(scale) + scale(Space.base))
        case .problem(_, let text):
            RowCaption(text, warns: true)
                .frame(maxWidth: .infinity, minHeight: scale(Size.menuRow), alignment: .leading)
                .padding(.leading, scale(Space.section) + SidebarRowLayout.chevronWidth(scale) + scale(Space.base))
                .background(ViewMark(name: row.id))
        case .node(let project, let node, let depth, let open):
            FileRow(project: project, node: node, depth: depth, open: open,
                    activate: { activate(node, in: project) },
                    openInEditor: { openFile(node, in: project) })
                .background(ViewMark(name: row.id))
        case .note(_, _, let text, let depth):
            RowCaption(text)
                .frame(maxWidth: .infinity, minHeight: scale(Size.menuRow), alignment: .leading)
                .padding(.leading, FileRow.leadingInset(depth: depth, scale) + SidebarRowLayout.chevronWidth(scale) + scale(Space.base))
                .background(ViewMark(name: row.id))
        }
    }

    private func activate(_ node: FileNode, in project: Project) {
        if node.isFolder { model.toggleFolder(project: project.id, folder: node) } else { openFile(node, in: project) }
    }

    private func openFile(_ node: FileNode, in project: Project) {
        Task { await opener.open(node, in: project, files: model) }
    }
}

/// A panel's own title, when it is not pinned above the panel: the Files, Git or SSH panel's, with
/// the panel's buttons, if any, at its end.
struct PanelTitle<Accessory: View>: View {
    let panel: ActivityPanel
    let accessory: Accessory
    @Environment(\.interfaceScale) private var scale

    init(panel: ActivityPanel, @ViewBuilder accessory: () -> Accessory) {
        self.panel = panel
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarHeading(panel.title)
            Spacer(minLength: 0)
            accessory
        }
        .frame(height: scale(Size.menuRow))
        .background(ViewMark(name: SidebarHeader.markName))
        .padding(.horizontal, SidebarRowLayout.listInset + scale(Space.base))
    }
}

extension PanelTitle where Accessory == EmptyView {
    init(panel: ActivityPanel) { self.init(panel: panel) { EmptyView() } }
}

/// A project's row in the Files panel: a chevron, its provider mark and its name, as its header in
/// Sessions has them. A click folds or unfolds the section.
private struct FilesProjectRow: View {
    let project: Project
    let open: Bool
    let provider: Provider
    let toggle: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            HeaderChevron(collapsed: !open).frame(width: SidebarRowLayout.chevronWidth(scale))
            ProviderIcon(provider: provider)
            HeaderTitle(text: project.name)
            Spacer(minLength: scale(Space.tight))
        }
        .frame(height: scale(Size.projectRow)).padding(.leading, scale(Space.base)).padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: false))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(project.name), project")
        .accessibilityValue(open ? FileRow.expanded : FileRow.collapsed)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityAction(named: Text(open ? FileRow.fold : FileRow.unfold), toggle)
        .contextMenu {
            Button(FileRow.revealTitle) { FileRow.reveal(project.path) }
            Divider()
            OpenInMenuItems(folder: project.path)
        }
    }
}

/// A file or folder of a project's tree: a folder's chevron, its symbol and its name, indented by
/// its depth. A folder folds or unfolds on a click; a file opens in the terminal editor.
private struct FileRow: View {
    let project: Project
    let node: FileNode
    let depth: Int
    let open: Bool
    let activate: () -> Void
    let openInEditor: () -> Void
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface

    static let folderSymbol = "folder"
    static let fileSymbol = "doc"
    /// The folder and file symbols' drawn size, as `ProviderIcon` draws its SF Symbol fallbacks in
    /// the same `Size.avatar` column, so a tree's symbols line up under the project's mark.
    private static let glyphSize: CGFloat = 10

    static let expanded = "Expanded"
    static let collapsed = "Collapsed"
    static let fold = "Fold"
    static let unfold = "Unfold"
    static let openTitle = "Open in Terminal Editor"
    static let revealTitle = "Reveal in Finder"

    private var path: String { URL(fileURLWithPath: project.path).appendingPathComponent(node.path).path }

    /// Where a row at `depth` starts: its chevron's column.
    static func leadingInset(depth: Int, _ scale: InterfaceScale) -> CGFloat {
        scale(Space.base) + scale(Space.block) * CGFloat(depth + 1)
    }

    var body: some View {
        HStack(spacing: scale(Space.base)) {
            HeaderChevron(collapsed: !open).frame(width: SidebarRowLayout.chevronWidth(scale))
                .opacity(node.isFolder ? 1 : 0)
            Icon(.symbol(node.isFolder ? Self.folderSymbol : Self.fileSymbol), size: scale(Self.glyphSize), tint: surface.secondaryInk)
                .frame(width: scale(Size.avatar), height: scale(Size.avatar))
            RowTitle(node.name)
            Spacer(minLength: scale(Space.tight))
        }
        .frame(height: scale(Size.menuRow))
        .padding(.leading, Self.leadingInset(depth: depth, scale))
        .padding(.trailing, SidebarRowLayout.trailingInset(scale))
        .modifier(RowPill(selected: false))
        .contentShape(Rectangle())
        .onTapGesture(perform: activate)
        .help(node.path)
        .modifier(FileRowAccessibility(name: node.name, isFolder: node.isFolder, open: open, activate: activate))
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        if node.isFolder {
            Button(Self.revealTitle) { Self.reveal(path) }
            Divider()
            OpenInMenuItems(folder: path)
        } else {
            Button(Self.openTitle, action: openInEditor)
            Button(Self.revealTitle) { Self.reveal(path) }
            if let item = OpenIn.vsCodeItem(file: path, vsCodeInstalled: OpenIn.vsCodeInstalled) {
                Divider()
                Button(item.title) { OpenIn.open(item) }
            }
        }
    }

    @MainActor static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// VoiceOver: a row is read as its name and kind; a folder says whether it is open, and offers Fold
/// or Unfold; a file's default action opens it.
private struct FileRowAccessibility: ViewModifier {
    let name: String
    let isFolder: Bool
    let open: Bool
    let activate: () -> Void

    func body(content: Content) -> some View {
        let labelled = content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name), \(isFolder ? "folder" : "file")")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { activate() }
        if isFolder {
            labelled
                .accessibilityValue(open ? FileRow.expanded : FileRow.collapsed)
                .accessibilityAction(named: Text(open ? FileRow.fold : FileRow.unfold), activate)
        } else {
            labelled
        }
    }
}

/// The app's one Files panel model, made the first time the panel is shown in any window: until
/// then no project is listed or watched. Every window's panel draws it; each opens files in its
/// own window.
@MainActor
public final class FilesHolder {
    private let make: @MainActor () -> FilesModel
    /// The model, once made; nil until then. Reading it makes nothing.
    private(set) var made: FilesModel?
    /// The windows showing the panel. While none does, the model's watchers only note what changed,
    /// and nothing is listed until a window shows the panel again.
    private lazy var viewers = PanelViewers { [weak self] shown in self?.made?.setShown(shown) }

    public init(_ make: @escaping @MainActor () -> FilesModel) { self.make = make }

    /// The model, made now if it has not been.
    var model: FilesModel {
        if let made { return made }
        let model = make()
        made = model
        return model
    }

    /// Told each time a window's panel registers: the host checks then whether that window's
    /// sidebar can be seen (`setVisible`), rather than on its next tick.
    public var onRegister: (@MainActor () -> Void)?

    /// A window shows the panel until the viewer is released, or goes.
    func register() -> PanelViewer {
        let viewer = viewers.register()
        onRegister?()
        return viewer
    }

    /// Whether a sidebar that can be seen (not hidden, not in the Dock, not covered) has the panel
    /// selected: the host's check, each second and when a window's visibility may have changed.
    public func setVisible(_ visible: Bool) { viewers.setVisible(visible) }

    /// How many windows show the panel. For tests.
    var viewerCount: Int { viewers.count }
}
