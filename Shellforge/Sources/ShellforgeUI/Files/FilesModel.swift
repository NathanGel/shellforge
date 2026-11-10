import Foundation
import ShellforgeCore

/// One project's part of the Files panel.
public struct FilesSection: Equatable, Identifiable {
    public var project: Project
    public var state: State
    public var id: UUID { project.id }

    public enum State: Equatable, Sendable {
        case loading
        case tree([FileNode])
        case missing
        case unreadable(String)
    }
}

/// The Files panel's trees, one per workspace project. Each project's folder is watched; a change
/// there lists that project again, off the main actor. Which folders are open is remembered per
/// project, on this Mac.
@MainActor
public final class FilesModel: ObservableObject {
    @Published public private(set) var sections: [FilesSection] = []

    /// Per project (its UUID string): the open folders' relative paths. "" is the project's own
    /// section, and is stored when it is CLOSED, since sections are open by default.
    static let expandedKey = "NoSyncShellforgeFilesExpanded"

    private let launcher: CommandLauncher
    private let defaults: UserDefaults
    private let makeWatcher: (String) -> FolderWatching
    private let list: @Sendable (String, CommandLauncher) -> ProjectFiles.Listing
    private var watchers: [UUID: FolderWatching] = [:]
    /// The newest refresh whose listing is showing, per project: one started earlier that finishes
    /// later is dropped, so the newest listing is what shows and none is lost to an overlap.
    private var applied: [UUID: Int] = [:]
    private var inflight: [UUID: Task<Void, Never>] = [:]
    private var nextTask = 0

    /// `list` is for tests that must see where listing runs; it defaults to `ProjectFiles.list`.
    public init(projects: [Project], launcher: CommandLauncher, defaults: UserDefaults,
                watcher: @escaping (String) -> FolderWatching,
                list: @escaping @Sendable (String, CommandLauncher) -> ProjectFiles.Listing = { ProjectFiles.list($0, launcher: $1) }) {
        self.launcher = launcher
        self.defaults = defaults
        self.makeWatcher = watcher
        self.list = list
        update(projects: projects)
    }

    // -- projects -------------------------------------------------------------------------

    public func update(projects: [Project]) {
        let ids = Set(projects.map(\.id))
        for id in watchers.keys where !ids.contains(id) {
            watchers.removeValue(forKey: id)?.stop()
            applied.removeValue(forKey: id)
            inflight.removeValue(forKey: id)?.cancel()
        }
        let existing = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added: [UUID] = []
        sections = projects.map { project in
            if var section = existing[project.id] {
                section.project = project
                return section
            }
            added.append(project.id)
            return FilesSection(project: project, state: .loading)
        }
        for project in projects where added.contains(project.id) {
            let watcher = makeWatcher(project.path)
            watchers[project.id] = watcher
            let id = project.id
            watcher.watch(project.path) { [weak self] in
                Task { @MainActor in self?.fileEvent(project: id) }
            }
            start(project: id)
        }
    }

    // -- open folders ---------------------------------------------------------------------

    public func isOpen(project: UUID, folder: String) -> Bool {
        let stored = expanded(project).contains(folder)
        return folder.isEmpty ? !stored : stored
    }

    public func toggle(project: UUID, folder: String) {
        var all = defaults.dictionary(forKey: Self.expandedKey) as? [String: [String]] ?? [:]
        var paths = all[project.uuidString] ?? []
        if let index = paths.firstIndex(of: folder) { paths.remove(at: index) } else { paths.append(folder) }
        all[project.uuidString] = paths.isEmpty ? nil : paths
        defaults.set(all, forKey: Self.expandedKey)
        objectWillChange.send()
    }

    private func expanded(_ project: UUID) -> [String] {
        (defaults.dictionary(forKey: Self.expandedKey) as? [String: [String]])?[project.uuidString] ?? []
    }

    // -- listing --------------------------------------------------------------------------

    /// Lists the project again; when it returns the section shows the newest listing started.
    public func refresh(project: UUID) async {
        guard let path = sections.first(where: { $0.id == project })?.project.path else { return }
        nextTask += 1
        let generation = nextTask
        let openFolders = expanded(project).filter { !$0.isEmpty }
        let list = self.list, launcher = self.launcher
        let state = await BackgroundWork.run { () -> FilesSection.State in
            Self.state(for: list(path, launcher), path: path, openFolders: openFolders)
        }
        guard generation > applied[project, default: 0], let index = sections.firstIndex(where: { $0.id == project }) else { return }
        applied[project] = generation
        sections[index].state = state
    }

    /// Fills in a folder of a project that is not in a repository, which is listed one level at a
    /// time. Nothing to do for a folder that is already loaded, or in a repository.
    public func loadChildren(project: UUID, folder: String) async {
        guard let section = sections.first(where: { $0.id == project }), case .tree(let nodes) = section.state,
              Self.node(at: folder, in: nodes)?.children == nil else { return }
        let path = section.project.path
        let children = await BackgroundWork.run { ProjectFiles.children(of: folder, in: path) }
        guard let index = sections.firstIndex(where: { $0.id == project }), case .tree(var current) = sections[index].state,
              Self.node(at: folder, in: current)?.children == nil else { return }
        Self.set(children, at: folder, in: &current)
        sections[index].state = .tree(current)
    }

    /// Waits for the refreshes that file events started (each waits for the one before it, so the
    /// newest of a project stands for all). The first yield lets an event's hop to the main actor
    /// run first. For tests.
    func settled() async {
        await Task.yield()
        for task in Array(inflight.values) { await task.value }
    }

    private func fileEvent(project: UUID) { start(project: project) }

    private func start(project: UUID) {
        let previous = inflight[project]
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await self?.refresh(project: project)
        }
        inflight[project] = task
    }

    // -- building -------------------------------------------------------------------------

    private nonisolated static func state(for listing: ProjectFiles.Listing, path: String, openFolders: [String]) -> FilesSection.State {
        switch listing {
        case .git(let paths):
            return .tree(FileTree.build(paths))
        case .folder(var nodes):
            // A refresh must not close what was open: open folders are read again, shallowest first.
            for folder in openFolders.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
                guard node(at: folder, in: nodes)?.isFolder == true else { continue }
                set(ProjectFiles.children(of: folder, in: path), at: folder, in: &nodes)
            }
            return .tree(nodes)
        case .missing:
            return .missing
        case .unreadable(let reason):
            return .unreadable(reason)
        }
    }

    private nonisolated static func node(at path: String, in nodes: [FileNode]) -> FileNode? {
        guard let first = path.split(separator: "/").first.map(String.init) else { return nil }
        guard let match = nodes.first(where: { $0.name == first }) else { return nil }
        let rest = path.split(separator: "/").dropFirst().joined(separator: "/")
        return rest.isEmpty ? match : node(at: rest, in: match.children ?? [])
    }

    private nonisolated static func set(_ children: [FileNode], at path: String, in nodes: inout [FileNode]) {
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first, let index = nodes.firstIndex(where: { $0.name == first }) else { return }
        if parts.count == 1 {
            nodes[index].children = children
        } else if var inner = nodes[index].children {
            set(children, at: parts.dropFirst().joined(separator: "/"), in: &inner)
            nodes[index].children = inner
        }
    }
}
