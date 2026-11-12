import Combine
import Foundation
import ShellforgeCore

/// A repository the Git panel shows: a project's folder, or a task's worktree.
public enum GitRepoID: Hashable, Sendable {
    case project(UUID)
    case task(UUID)
}

/// One repository's part of the Git panel. A project's section holds its tasks that have changes.
public struct GitSection: Identifiable, Equatable {
    public var id: GitRepoID
    public var title: String
    public var path: String
    public var state: State
    /// An action is running.
    public var busy: Bool
    /// What went wrong, in plain words: shown until the next action on this repository.
    public var problem: String?
    public var tasks: [GitSection]

    public enum State: Equatable, Sendable {
        case loading
        case status(GitStatus)
        case notARepository
        case missing
    }
}

/// What the panel asks of a repository.
public enum GitAction: Equatable, Sendable {
    case stage([String])
    case unstage([String])
    /// An unstaged change, thrown away.
    case discard(GitChange)
    /// Commits with the repository's message draft, which is cleared once the commit is made.
    case commit
    case push
    case pull
}

/// The Git panel's repositories: every workspace project and its tasks' worktrees. Each one is
/// watched; a change there reads that repository again, off the main actor. A repository does one
/// thing at a time: its refreshes and actions wait in one serial queue, and events during an
/// action make one refresh after it. The app has one, which every window's panel draws; the host
/// makes it when the panel is first shown, so nothing is read or watched before.
@MainActor
public final class GitModel: ObservableObject {
    @Published public private(set) var sections: [GitSection] = []

    typealias Read = @Sendable (_ path: String, _ launcher: CommandLauncher) throws -> GitStatus
    typealias Act = @Sendable (_ action: GitAction, _ repo: String, _ message: String, _ launcher: CommandLauncher) throws -> Void

    private struct Repo {
        var title: String
        var path: String
        /// The project the repository belongs to: its own id for a project.
        var projectId: UUID
        var state: GitSection.State = .loading
        var busy = false
        var actionProblem: String?
        var readProblem: String?
    }

    /// What a read found. A nil state keeps what is shown.
    private struct Loaded: Sendable {
        var state: GitSection.State?
        var problem: String?
        var worktreeName: String?
    }

    private let launcher: CommandLauncher
    private let makeWatcher: (String) -> FolderWatching
    private let read: Read
    private let act: Act
    private var repos: [GitRepoID: Repo] = [:]
    private var projectOrder: [UUID] = []
    private var taskOrder: [UUID] = []
    /// A task's folder in the main repository's `.git/worktrees/`, where its index lives.
    private var worktreeNames: [UUID: String] = [:]
    private var watchers: [GitRepoID: FolderWatching] = [:]
    /// Commit message drafts, in memory only.
    private var drafts: [GitRepoID: String] = [:]
    /// A repository's epoch changes when it is added, removed or its folder changes; work queued
    /// or started in an earlier epoch is dropped, so it cannot land on a section it was not for.
    private var epochs: [GitRepoID: Int] = [:]
    /// The newest read whose result is showing, per repository: an older one never overwrites it.
    private var applied: [GitRepoID: Int] = [:]
    private var counter = 0
    /// Each repository's serial queue: the last operation queued, which waits for the one before.
    private var tails: [GitRepoID: Task<Void, Never>] = [:]
    private var tailTokens: [GitRepoID: Int] = [:]
    /// A refresh queued and not yet started: further events join it rather than queue another.
    private var pendingRefresh: [GitRepoID: (token: Int, task: Task<Void, Never>)] = [:]
    /// Queued refreshes another read made needless: they do nothing when their turn comes.
    private var absorbed: Set<Int> = []
    private let hops = EventHops()
    /// Told each time an operation is queued. For tests.
    var enqueued: ((GitRepoID) -> Void)?

    public convenience init(projects: [Project], tasks: [TaskItem], launcher: CommandLauncher,
                            watcher: @escaping (String) -> FolderWatching) {
        self.init(projects: projects, tasks: tasks, launcher: launcher, watcher: watcher,
                  read: { try GitStatus.read($0, launcher: $1) }, act: { try GitModel.run($0, in: $1, message: $2, launcher: $3) })
    }

    /// `read` and `act` are for tests that must count reads or hold an action.
    init(projects: [Project], tasks: [TaskItem], launcher: CommandLauncher,
         watcher: @escaping (String) -> FolderWatching, read: @escaping Read, act: @escaping Act) {
        self.launcher = launcher
        self.makeWatcher = watcher
        self.read = read
        self.act = act
        update(projects: projects, tasks: tasks)
    }

    // -- repositories ---------------------------------------------------------------------

    public func update(projects: [Project], tasks: [TaskItem]) {
        let projectIds = Set(projects.map(\.id))
        let kept = tasks.filter { projectIds.contains($0.projectId) }
        var wanted: [GitRepoID: Repo] = [:]
        for project in projects {
            wanted[.project(project.id)] = Repo(title: project.name, path: project.path, projectId: project.id)
        }
        for task in kept {
            wanted[.task(task.id)] = Repo(title: task.title, path: task.worktreePath, projectId: task.projectId)
        }
        for id in Array(repos.keys) where wanted[id] == nil { forget(id) }
        projectOrder = projects.map(\.id)
        taskOrder = kept.map(\.id)
        for (id, repo) in wanted {
            if var existing = repos[id] {
                if existing.path == repo.path {
                    existing.title = repo.title
                    existing.projectId = repo.projectId
                    repos[id] = existing
                    continue
                }
                forget(id)   // its folder moved: another repository, another watcher
            }
            start(id, repo)
        }
        publish()
    }

    private func start(_ id: GitRepoID, _ repo: Repo) {
        counter += 1
        epochs[id] = counter
        repos[id] = repo
        if case .task(let task) = id { worktreeNames[task] = (repo.path as NSString).lastPathComponent }
        let watcher = makeWatcher(repo.path)
        watchers[id] = watcher
        watcher.watch(repo.path) { [weak self, hops] changes in
            hops.hop { self?.changed(id, changes) }
        }
        refreshSoon(id)
    }

    private func forget(_ id: GitRepoID) {
        watchers.removeValue(forKey: id)?.stop()
        repos[id] = nil
        epochs[id] = nil
        applied[id] = nil
        drafts[id] = nil
        if let pending = pendingRefresh.removeValue(forKey: id) { absorbed.insert(pending.token) }
        if case .task(let task) = id { worktreeNames[task] = nil }
    }

    // -- events ---------------------------------------------------------------------------

    /// A project's watcher also sees its tasks' index and HEAD, under `.git/worktrees/<name>/`:
    /// those refresh the task. Not knowing what changed refreshes the project and its tasks.
    private func changed(_ id: GitRepoID, _ changes: [String]) {
        guard watchers[id] != nil else { return }   // a late event for a repository that is gone
        guard case .project(let project) = id else {
            refreshSoon(id)
            return
        }
        let tasks = taskOrder.filter { repos[.task($0)]?.projectId == project }
        if changes.isEmpty {
            refreshSoon(id)
            for task in tasks { refreshSoon(.task(task)) }
            return
        }
        var projectChanged = false
        var tasksChanged: Set<UUID> = []
        for change in changes {
            if let name = GitWatchPaths.worktreeName(change) {
                tasksChanged.formUnion(tasks.filter { worktreeNames[$0] == name })
            } else {
                projectChanged = true
            }
        }
        if projectChanged { refreshSoon(id) }
        for task in tasks where tasksChanged.contains(task) { refreshSoon(.task(task)) }
    }

    // -- the queue ------------------------------------------------------------------------

    /// Queues `operation` behind everything already queued for `id`.
    @discardableResult
    private func enqueue(_ id: GitRepoID, token: Int? = nil, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tails[id]
        let token = token ?? next()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await operation()
            // Only the operation still last in the queue clears it.
            if let self, self.tailTokens[id] == token {
                self.tails[id] = nil
                self.tailTokens[id] = nil
            }
        }
        tails[id] = task
        tailTokens[id] = token
        enqueued?(id)
        return task
    }

    private func next() -> Int {
        counter += 1
        return counter
    }

    /// A refresh queued now, or the one already queued and not started.
    @discardableResult
    private func refreshSoon(_ id: GitRepoID) -> Task<Void, Never>? {
        if let pending = pendingRefresh[id] { return pending.task }
        guard let epoch = epochs[id] else { return nil }
        let token = next()
        let task = enqueue(id, token: token) { [weak self] in
            guard let self else { return }
            if self.pendingRefresh[id]?.token == token { self.pendingRefresh[id] = nil }
            guard self.absorbed.remove(token) == nil else { return }
            await self.load(id, epoch: epoch)
        }
        pendingRefresh[id] = (token, task)
        return task
    }

    // -- reading --------------------------------------------------------------------------

    /// Reads the repository again, after what is queued for it; when it returns the section shows
    /// what was read.
    public func refresh(_ repo: GitRepoID) async {
        await refreshSoon(repo)?.value
    }

    /// Reads the repository now: called from its queue only.
    private func load(_ id: GitRepoID, epoch: Int) async {
        guard epochs[id] == epoch, let repo = repos[id] else { return }
        // A refresh queued behind this read would read the same: it is dropped.
        if let pending = pendingRefresh.removeValue(forKey: id) { absorbed.insert(pending.token) }
        let generation = next()
        let path = repo.path, read = self.read, launcher = self.launcher
        let isTask: Bool
        if case .task = id { isTask = true } else { isTask = false }
        let loaded = await BackgroundWork.run { Self.load(path, isTask: isTask, read: read, launcher: launcher) }
        guard epochs[id] == epoch, generation > applied[id, default: 0], repos[id] != nil else { return }
        applied[id] = generation
        if let state = loaded.state {
            repos[id]?.state = state
            repos[id]?.readProblem = nil
        }
        if let problem = loaded.problem { repos[id]?.readProblem = problem }
        if let name = loaded.worktreeName, case .task(let task) = id { worktreeNames[task] = name }
        publish()
    }

    private nonisolated static func load(_ path: String, isTask: Bool, read: Read, launcher: CommandLauncher) -> Loaded {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            return Loaded(state: .missing)
        }
        let name = isTask ? worktreeName(of: path) : nil
        do {
            return Loaded(state: .status(try read(path, launcher)), worktreeName: name)
        } catch let failure as GitFailure {
            if failure.message.contains("not a git repository") { return Loaded(state: .notARepository, worktreeName: name) }
            return Loaded(problem: failure.message, worktreeName: name)
        } catch {
            return Loaded(problem: "git: \(error.localizedDescription)", worktreeName: name)
        }
    }

    /// A worktree's folder in the main repository's `.git/worktrees/`, from its `.git` file
    /// (`gitdir: <main>/.git/worktrees/<name>`); its own folder's name when that cannot be read.
    private nonisolated static func worktreeName(of path: String) -> String {
        let fallback = (path as NSString).lastPathComponent
        guard let text = try? String(contentsOfFile: (path as NSString).appendingPathComponent(".git"), encoding: .utf8),
              text.hasPrefix("gitdir:") else { return fallback }
        let gitdir = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return gitdir.isEmpty ? fallback : (gitdir as NSString).lastPathComponent
    }

    // -- actions --------------------------------------------------------------------------

    /// Runs `action` after what is queued for the repository, then reads it again; when it
    /// returns the section shows the outcome. A failure is the section's problem until the next
    /// action.
    public func perform(_ action: GitAction, in repo: GitRepoID) async {
        guard let epoch = epochs[repo] else { return }
        await enqueue(repo) { [weak self] in await self?.run(action, in: repo, epoch: epoch) }.value
    }

    private func run(_ action: GitAction, in id: GitRepoID, epoch: Int) async {
        guard epochs[id] == epoch, let repo = repos[id] else { return }
        repos[id]?.busy = true
        repos[id]?.actionProblem = nil
        repos[id]?.readProblem = nil
        publish()
        let message = drafts[id] ?? ""
        let act = self.act, launcher = self.launcher, path = repo.path
        let problem = await BackgroundWork.run { () -> String? in
            do {
                try act(action, path, message, launcher)
                return nil
            } catch let failure as GitFailure {
                return failure.message
            } catch {
                return "git: \(error.localizedDescription)"
            }
        }
        guard epochs[id] == epoch, repos[id] != nil else { return }
        repos[id]?.busy = false
        repos[id]?.actionProblem = problem
        // A message typed while the commit ran is kept.
        if action == .commit, problem == nil, drafts[id] == message, !message.isEmpty {
            objectWillChange.send()
            drafts[id] = nil
        }
        publish()
        await load(id, epoch: epoch)
    }

    /// What `act` does outside tests. Discard and unstage work from the repository as it is now:
    /// discard takes only an unstaged change, and unstaging a rename takes its old path too.
    nonisolated static func run(_ action: GitAction, in repo: String, message: String, launcher: CommandLauncher) throws {
        switch action {
        case .stage(let paths):
            try GitActions.stage(paths, in: repo, launcher: launcher)
        case .unstage(let paths):
            let staged = try GitStatus.read(repo, launcher: launcher).staged.filter { paths.contains($0.path) }
            var all = paths
            for original in staged.compactMap(\.originalPath) where !all.contains(original) { all.append(original) }
            try GitActions.unstage(all, in: repo, launcher: launcher)
        case .discard(let change):
            guard let current = try GitStatus.read(repo, launcher: launcher).unstaged.first(where: { $0.path == change.path }) else {
                throw GitFailure(message: "\(change.path) has no changes to discard.")
            }
            try GitActions.discard(current, in: repo, launcher: launcher)
        case .commit:
            let status = try GitStatus.read(repo, launcher: launcher)
            try GitActions.commit(message: message, in: repo, status: status, launcher: launcher)
        case .push:
            let status = try GitStatus.read(repo, launcher: launcher)
            try GitActions.push(in: repo, status: status, launcher: launcher)
        case .pull:
            try GitActions.pull(in: repo, launcher: launcher)
        }
    }

    // -- commit messages ------------------------------------------------------------------

    public func commitMessage(_ repo: GitRepoID) -> String { drafts[repo] ?? "" }

    public func setCommitMessage(_ text: String, for repo: GitRepoID) {
        guard repos[repo] != nil, commitMessage(repo) != text else { return }
        objectWillChange.send()
        drafts[repo] = text.isEmpty ? nil : text
    }

    // -- tests ----------------------------------------------------------------------------

    /// Waits until every event the watchers have reported has been taken in. For tests.
    func eventsDelivered() async {
        await hops.delivered()
    }

    /// Waits until the events reported so far have been taken in and every queue is empty. For tests.
    func settled() async {
        await eventsDelivered()
        while let tail = tails.values.first { await tail.value }
    }

    // -- sections -------------------------------------------------------------------------

    private func publish() {
        let built = projectOrder.compactMap { project -> GitSection? in
            guard let repo = repos[.project(project)] else { return nil }
            let tasks = taskOrder.compactMap { task -> GitSection? in
                guard let repo = repos[.task(task)], repo.projectId == project,
                      case .status(let status) = repo.state, status.hasChanges else { return nil }
                return section(.task(task), repo, tasks: [])
            }
            return section(.project(project), repo, tasks: tasks)
        }
        if built != sections { sections = built }
    }

    private func section(_ id: GitRepoID, _ repo: Repo, tasks: [GitSection]) -> GitSection {
        GitSection(id: id, title: repo.title, path: repo.path, state: repo.state, busy: repo.busy,
                   problem: repo.actionProblem ?? repo.readProblem, tasks: tasks)
    }
}
