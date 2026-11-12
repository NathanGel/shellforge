import Combine
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
/// project, on this Mac. The app has one, which every window's panel draws.
@MainActor
public final class FilesModel: ObservableObject {
    @Published public private(set) var sections: [FilesSection] = []

    /// Per project (its UUID string): the open folders' relative paths. "" is the project's own
    /// section, and is stored when it is CLOSED, since sections are open by default.
    static let expandedKey = "NoSyncShellforgeFilesExpanded"

    private let launcher: CommandLauncher
    private let defaults: UserDefaults
    /// `expandedKey`'s value, read once: the app has one model, so nothing else writes it.
    private var stored: [String: [String]]
    private let makeWatcher: (String) -> FolderWatching
    private let list: @Sendable (String, CommandLauncher) -> ProjectFiles.Listing
    private var watchers: [UUID: FolderWatching] = [:]
    /// A project's epoch changes when it is added, removed or its folder changes; a listing that
    /// started in an earlier epoch is dropped, so it cannot land on a section it was not for.
    private var epochs: [UUID: Int] = [:]
    /// The newest refresh whose listing is showing, per project: one started earlier that finishes
    /// later is dropped, so the newest listing wins and none is lost to an overlap.
    private var applied: [UUID: Int] = [:]
    private var counter = 0
    /// A project's running refresh loop, and whether an event came while it ran (one more
    /// refresh follows, however many events there were).
    private var loops: [UUID: Task<Void, Never>] = [:]
    private var dirty: Set<UUID> = []
    private var loopTokens: [UUID: Int] = [:]
    /// Events handed from the watcher's queue to the main actor, so tests can await them. Each
    /// hop leaves once it has run, so a long session keeps none.
    private let hops = Hops()

    private final class Hops: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var tasks: [Int: Task<Void, Never>] = [:]
        /// Hops that finished before they were added: `add` then keeps nothing.
        private var finished: Set<Int> = []
        /// The id the next hop's task is made with, taken before the task is made.
        func reserve() -> Int { lock.withLock { next += 1; return next } }
        func add(_ id: Int, _ task: Task<Void, Never>) {
            lock.withLock { if finished.remove(id) == nil { tasks[id] = task } }
        }
        func finish(_ id: Int) {
            lock.withLock { if tasks.removeValue(forKey: id) == nil { finished.insert(id) } }
        }
        /// The hops still kept.
        func pending() -> [Task<Void, Never>] { lock.withLock { Array(tasks.values) } }
        var count: Int { lock.withLock { tasks.count } }
    }

    /// `list` is for tests that must see where listing runs; it defaults to `ProjectFiles.list`.
    public init(projects: [Project], launcher: CommandLauncher, defaults: UserDefaults,
                watcher: @escaping (String) -> FolderWatching,
                list: @escaping @Sendable (String, CommandLauncher) -> ProjectFiles.Listing = { ProjectFiles.list($0, launcher: $1) }) {
        self.launcher = launcher
        self.defaults = defaults
        self.stored = defaults.dictionary(forKey: Self.expandedKey) as? [String: [String]] ?? [:]
        self.makeWatcher = watcher
        self.list = list
        update(projects: projects)
    }

    // -- projects -------------------------------------------------------------------------

    private var following: AnyCancellable?

    /// Follows the workspace's projects, delivered on the main thread: added, removed or reordered
    /// in Sessions, the sections follow in the workspace's order.
    public func follow(_ projects: some Publisher<[Project], Never>) {
        following = projects.removeDuplicates().sink { [weak self] projects in
            MainActor.assumeIsolated { self?.update(projects: projects) }
        }
    }

    public func update(projects: [Project]) {
        let ids = Set(projects.map(\.id))
        for id in Array(watchers.keys) where !ids.contains(id) { forget(id) }
        let existing = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var started: [UUID] = []
        sections = projects.map { project in
            if var section = existing[project.id] {
                guard section.project.path != project.path else {
                    section.project = project
                    return section
                }
                forget(project.id)   // its folder moved: another tree, another watcher
            }
            started.append(project.id)
            return FilesSection(project: project, state: .loading)
        }
        for project in projects where started.contains(project.id) {
            counter += 1
            epochs[project.id] = counter
            let watcher = makeWatcher(project.path)
            watchers[project.id] = watcher
            let id = project.id
            watcher.watch(project.path) { [weak self, hops] in
                let hop = hops.reserve()
                hops.add(hop, Task { @MainActor in
                    self?.fileEvent(project: id)
                    hops.finish(hop)
                })
            }
            startLoop(project: id)
        }
    }

    private func forget(_ id: UUID) {
        watchers.removeValue(forKey: id)?.stop()
        epochs[id] = nil
        applied[id] = nil
        dirty.remove(id)
        loops.removeValue(forKey: id)?.cancel()
        loopTokens[id] = nil
    }

    // -- open folders ---------------------------------------------------------------------

    public func isOpen(project: UUID, folder: String) -> Bool {
        let stored = expanded(project).contains(folder)
        return folder.isEmpty ? !stored : stored
    }

    public func toggle(project: UUID, folder: String) {
        var paths = stored[project.uuidString] ?? []
        if let index = paths.firstIndex(of: folder) { paths.remove(at: index) } else { paths.append(folder) }
        objectWillChange.send()
        stored[project.uuidString] = paths.isEmpty ? nil : paths
        defaults.set(stored, forKey: Self.expandedKey)
    }

    private func expanded(_ project: UUID) -> [String] { stored[project.uuidString] ?? [] }

    // -- listing --------------------------------------------------------------------------

    /// Lists the project again; when it returns the section shows the newest listing started. A
    /// listing that changes nothing is not published, so no window draws the panel again for it.
    public func refresh(project: UUID) async {
        guard let epoch = epochs[project], let section = sections.first(where: { $0.id == project }) else { return }
        let path = section.project.path, shown = section.state
        counter += 1
        let generation = counter
        let openFolders = expanded(project).filter { !$0.isEmpty }
        let list = self.list, launcher = self.launcher
        let (state, plainFolder) = await BackgroundWork.run { () -> (FilesSection.State?, Bool) in
            let listing = list(path, launcher)
            let state = Self.state(for: listing, path: path, openFolders: openFolders)
            let plainFolder: Bool
            if case .folder = listing { plainFolder = true } else { plainFolder = false }
            return (state == shown ? nil : state, plainFolder)
        }
        guard !Task.isCancelled, epochs[project] == epoch, generation > applied[project, default: 0],
              let index = sections.firstIndex(where: { $0.id == project }) else { return }
        applied[project] = generation
        if let state { sections[index].state = state }
        // A plain folder's folder opened while this listing ran was not read with it, and may have
        // lost what its own load put in: one more refresh reads it. A repository's tree is whole.
        if plainFolder, expanded(project).contains(where: { !$0.isEmpty && !openFolders.contains($0) }) { refreshSoon(project: project) }
    }

    /// Fills in a folder of a project that is not in a repository, which is listed one level at a
    /// time, and its subfolders still stored open. Nothing to do for a folder that is already
    /// loaded, or in a repository.
    public func loadChildren(project: UUID, folder: String) async {
        guard let epoch = epochs[project], let section = sections.first(where: { $0.id == project }),
              case .tree(let nodes) = section.state, Self.node(at: folder, in: nodes)?.children == nil else { return }
        let path = section.project.path
        let openFolders = expanded(project)
        let children = await BackgroundWork.run { () -> [FileNode] in
            var tree = nodes
            Self.set(ProjectFiles.children(of: folder, in: path), at: folder, in: &tree)
            Self.fill(&tree, openFolders: openFolders, under: folder, path: path)
            return Self.node(at: folder, in: tree)?.children ?? []
        }
        guard !Task.isCancelled, epochs[project] == epoch, let index = sections.firstIndex(where: { $0.id == project }),
              case .tree(var current) = sections[index].state, Self.node(at: folder, in: current)?.children == nil else { return }
        Self.set(children, at: folder, in: &current)
        sections[index].state = .tree(current)
    }

    /// Waits until every event the watchers have reported has been taken in. For tests.
    func eventsDelivered() async {
        for hop in hops.pending() { await hop.value }
    }

    /// The events handed to the main actor that have not run yet. For tests.
    var pendingHops: Int { hops.count }

    /// Waits until the events reported so far have been taken in and their refreshes are done.
    /// For tests.
    func settled() async {
        await eventsDelivered()
        for loop in Array(loops.values) { await loop.value }
    }

    private func fileEvent(project: UUID) {
        guard watchers[project] != nil else { return }   // a late event for a project that is gone
        refreshSoon(project: project)
    }

    /// One more refresh after the running one, or one now.
    private func refreshSoon(project: UUID) {
        if loops[project] != nil { dirty.insert(project) } else { startLoop(project: project) }
    }

    /// Refreshes, and again once more if events came meanwhile.
    private func startLoop(project: UUID) {
        counter += 1
        let token = counter
        loopTokens[project] = token
        loops[project] = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh(project: project)
                guard !Task.isCancelled, self.dirty.remove(project) != nil else { break }
            }
            // Only the loop still registered for the project clears it: a project removed and
            // added again has a loop of its own by now.
            if let self, self.loopTokens[project] == token {
                self.loops[project] = nil
                self.loopTokens[project] = nil
            }
        }
    }

    // -- building -------------------------------------------------------------------------

    private nonisolated static func state(for listing: ProjectFiles.Listing, path: String, openFolders: [String]) -> FilesSection.State {
        switch listing {
        case .git(let paths, let submodules):
            return .tree(FileTree.build(paths, submodules: submodules))
        case .folder(var nodes):
            // A refresh must not close what was open.
            fill(&nodes, openFolders: openFolders, under: nil, path: path)
            return .tree(nodes)
        case .missing:
            return .missing
        case .unreadable(let reason):
            return .unreadable(reason)
        }
    }

    /// Reads the open folders of a folder that is not in a repository, shallowest first: every
    /// one when `folder` is nil, else those inside `folder`. One whose parent is not loaded stays
    /// unloaded, and is read when its parent is opened.
    nonisolated static func fill(_ nodes: inout [FileNode], openFolders: [String], under folder: String?, path: String) {
        let inside = openFolders.filter { open in
            guard !open.isEmpty else { return false }
            guard let folder else { return true }
            return open.hasPrefix(folder + "/")
        }
        for open in inside.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            guard node(at: open, in: nodes)?.isFolder == true else { continue }
            set(ProjectFiles.children(of: open, in: path), at: open, in: &nodes)
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
