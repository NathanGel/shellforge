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

/// A repository's commit message as it is typed.
@MainActor
public final class CommitDraft: ObservableObject {
    @Published public var text = ""
}

/// What the panel asks of a repository.
public enum GitAction: Equatable, Sendable {
    case stage([String])
    case unstage([String])
    /// Every change, task worktrees left out; no path list on the command line.
    case stageAll
    case unstageAll
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
    /// Moves a file to the Trash: what discarding an untracked file does.
    public typealias Trash = @Sendable (URL) throws -> Void

    private struct Repo {
        var title: String
        var path: String
        /// The project the repository belongs to: its own id for a project.
        var projectId: UUID
        var state: GitSection.State = .loading
        var busy = false
        var actionProblem: String?
        var readProblem: String?
        /// A task's base branch, which commits on a branch with no upstream are counted against.
        var baseBranch: String?
        /// A task's commits on a branch with no upstream that its base branch lacks.
        var localCommits = 0
    }

    /// What a read found. A nil state keeps what is shown.
    private struct Loaded: Sendable {
        var state: GitSection.State?
        var problem: String?
        var worktreeName: String?
        var localCommits = 0
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
    /// Commit message drafts, in memory only. Each is its own object, so typing redraws its field
    /// and not the panel.
    private var drafts: [GitRepoID: CommitDraft] = [:]
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
    private var following: AnyCancellable?
    /// Told each time an operation is queued. For tests.
    var enqueued: ((GitRepoID) -> Void)?

    /// `trash` is for tests, which must not fill the real Trash.
    public convenience init(projects: [Project], tasks: [TaskItem], launcher: CommandLauncher,
                            watcher: @escaping (String) -> FolderWatching,
                            trash: @escaping Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.init(projects: projects, tasks: tasks, launcher: launcher, watcher: watcher,
                  read: { try GitStatus.read($0, launcher: $1) },
                  act: { try GitModel.run($0, in: $1, message: $2, launcher: $3, trash: trash) })
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

    /// Follows the workspace's projects and tasks: the publisher hands over the current ones at
    /// once, then each change.
    public func follow(_ workspace: some Publisher<Workspace, Never>) {
        following = workspace.map { ($0.projects, $0.tasks) }.removeDuplicates(by: ==).sink { [weak self] projects, tasks in
            MainActor.assumeIsolated { self?.update(projects: projects, tasks: tasks) }
        }
    }

    public func update(projects: [Project], tasks: [TaskItem]) {
        let projectIds = Set(projects.map(\.id))
        let kept = tasks.filter { projectIds.contains($0.projectId) }
        var wanted: [GitRepoID: Repo] = [:]
        for project in projects {
            wanted[.project(project.id)] = Repo(title: project.name, path: project.path, projectId: project.id)
        }
        for task in kept {
            wanted[.task(task.id)] = Repo(title: task.title, path: task.worktreePath, projectId: task.projectId,
                                          baseBranch: task.baseBranch)
        }
        for id in Array(repos.keys) where wanted[id] == nil { forget(id) }
        projectOrder = projects.map(\.id)
        taskOrder = kept.map(\.id)
        for (id, repo) in wanted {
            if var existing = repos[id] {
                if existing.path == repo.path {
                    existing.title = repo.title
                    existing.projectId = repo.projectId
                    existing.baseBranch = repo.baseBranch
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
        if case .task(let task) = id { resolveWorktreeName(task, path: repo.path, epoch: counter) }
        let watcher = makeWatcher(repo.path)
        watchers[id] = watcher
        watcher.watch(repo.path, onChanges: { [weak self, hops] changes in
            hops.hop { self?.changed(id, changes) }
        })
        refreshSoon(id)
    }

    /// Finds the task's folder in `.git/worktrees/` before anything else is queued for it, so the
    /// project's watcher routes its index changes from the start.
    private func resolveWorktreeName(_ task: UUID, path: String, epoch: Int) {
        worktreeNames[task] = (path as NSString).lastPathComponent
        let id = GitRepoID.task(task)
        enqueue(id) { [weak self] in
            let name = await BackgroundWork.run { Self.worktreeName(of: path) }
            guard let self, self.epochs[id] == epoch else { return }
            self.worktreeNames[task] = name
        }
    }

    private func forget(_ id: GitRepoID) {
        watchers.removeValue(forKey: id)?.stop()
        repos[id] = nil
        epochs[id] = nil
        applied[id] = nil
        drafts.removeValue(forKey: id)?.text = ""
        if let pending = pendingRefresh.removeValue(forKey: id) { absorbed.insert(pending.token) }
        if case .task(let task) = id { worktreeNames[task] = nil }
    }

    // -- events ---------------------------------------------------------------------------

    /// A project's watcher also sees its tasks' index and HEAD, under `.git/worktrees/<name>/`:
    /// those refresh the task. Refs and HEAD are shared by every worktree, so a change there
    /// (a fetch, a push) refreshes the project and its listed tasks, whose ahead and behind may
    /// have moved. Not knowing what changed refreshes the project and all its tasks.
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
                if GitWatchPaths.isShared(change) { tasksChanged.formUnion(tasks.filter(isListed)) }
            }
        }
        if projectChanged { refreshSoon(id) }
        for task in tasks where tasksChanged.contains(task) { refreshSoon(.task(task)) }
    }

    private func isListed(_ task: UUID) -> Bool {
        repos[.task(task)].map(Self.isShown) ?? false
    }

    /// A task's section shows while there is something to do or see in it: changes, commits not
    /// pushed (ahead of its upstream, or with none, commits its base branch lacks), or a problem.
    private static func isShown(_ repo: Repo) -> Bool {
        if repo.actionProblem != nil || repo.readProblem != nil { return true }
        guard case .status(let status) = repo.state else { return false }
        if status.hasChanges { return true }
        return status.upstream == nil ? repo.localCommits > 0 : status.ahead > 0
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
        let path = repo.path, read = self.read, launcher = self.launcher, base = repo.baseBranch
        let isTask: Bool
        if case .task = id { isTask = true } else { isTask = false }
        let loaded = await BackgroundWork.run { Self.load(path, isTask: isTask, base: base, read: read, launcher: launcher) }
        guard epochs[id] == epoch, generation > applied[id, default: 0], repos[id] != nil else { return }
        applied[id] = generation
        if let state = loaded.state {
            repos[id]?.state = state
            repos[id]?.readProblem = nil
            repos[id]?.localCommits = loaded.localCommits
        }
        if let problem = loaded.problem { repos[id]?.readProblem = problem }
        if let name = loaded.worktreeName, case .task(let task) = id { worktreeNames[task] = name }
        publish()
    }

    private nonisolated static func load(_ path: String, isTask: Bool, base: String?, read: Read,
                                         launcher: CommandLauncher) -> Loaded {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
            return Loaded(state: .missing)
        }
        let name = isTask ? worktreeName(of: path) : nil
        do {
            let status = try read(path, launcher)
            var loaded = Loaded(state: .status(status), worktreeName: name)
            if isTask, status.upstream == nil, case .branch = status.head, let base {
                loaded.localCommits = commits(in: path, notOn: base, launcher: launcher)
            }
            return loaded
        } catch let failure as GitFailure {
            if failure.message.contains("not a git repository") { return Loaded(state: .notARepository, worktreeName: name) }
            return Loaded(problem: failure.message, worktreeName: name)
        } catch {
            return Loaded(problem: "git: \(error.localizedDescription)", worktreeName: name)
        }
    }

    /// A local git call's limit, as `GitStatus.read` has.
    private nonisolated static let countTimeout: TimeInterval = 30

    /// `git rev-list --count <base>..HEAD`: commits a branch with no upstream has that its base
    /// lacks. 0 when it can't be counted (a base that is gone, say).
    private nonisolated static func commits(in path: String, notOn base: String, launcher: CommandLauncher) -> Int {
        guard !base.isEmpty, !base.hasPrefix("-"),
              let out = try? launcher.run("git", ["-C", path, "rev-list", "--count", "\(base)..HEAD"],
                                          extra: ["LC_ALL": "C", "GIT_OPTIONAL_LOCKS": "0"], timeout: Self.countTimeout),
              !out.timedOut, out.status == 0 else { return 0 }
        return Int(out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
        let message = commitMessage(id)
        let act = self.act, launcher = self.launcher
        await busy(id, epoch: epoch, work: { repo in
            let path = repo.path
            return await BackgroundWork.run { () -> String? in
                do {
                    try act(action, path, message, launcher)
                    return nil
                } catch {
                    return Self.problem(error)
                }
            }
        }, done: { [weak self] problem in
            // A message typed while the commit ran is kept.
            guard let self, action == .commit, problem == nil, self.commitMessage(id) == message, !message.isEmpty else { return }
            self.drafts[id]?.text = ""
        })
    }

    /// Marks the repository busy, does `work`, which returns its problem, then reads the
    /// repository again: busy until that read shows the outcome. `done` sees the problem first.
    private func busy(_ id: GitRepoID, epoch: Int, work: (Repo) async -> String?, done: (String?) -> Void = { _ in }) async {
        guard epochs[id] == epoch, let repo = repos[id] else { return }
        repos[id]?.busy = true
        repos[id]?.actionProblem = nil
        repos[id]?.readProblem = nil
        publish()
        let problem = await work(repo)
        guard epochs[id] == epoch, repos[id] != nil else { return }
        repos[id]?.actionProblem = problem
        done(problem)
        publish()
        await load(id, epoch: epoch)
        guard epochs[id] == epoch, repos[id] != nil else { return }
        repos[id]?.busy = false
        publish()
    }

    private nonisolated static func problem(_ error: Error) -> String {
        (error as? GitFailure)?.message ?? "git: \(error.localizedDescription)"
    }

    /// What `act` does outside tests. Discard and unstage work from the repository as it is now:
    /// discard takes only an unstaged change, and unstaging a rename takes its old path too.
    nonisolated static func run(_ action: GitAction, in repo: String, message: String, launcher: CommandLauncher,
                                trash: Trash = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        switch action {
        case .stage(let paths):
            try GitActions.stage(paths, in: repo, launcher: launcher)
        case .stageAll:
            try GitActions.stageAll(in: repo, launcher: launcher)
        case .unstageAll:
            try GitActions.unstageAll(in: repo, launcher: launcher)
        case .unstage(let paths):
            let staged = try GitStatus.read(repo, launcher: launcher).staged.filter { paths.contains($0.path) }
            var all = paths
            for original in staged.compactMap(\.originalPath) where !all.contains(original) { all.append(original) }
            try GitActions.unstage(all, in: repo, launcher: launcher)
        case .discard(let change):
            guard let current = try GitStatus.read(repo, launcher: launcher).unstaged.first(where: { $0.path == change.path }) else {
                throw GitFailure(message: "\(change.path) has no changes to discard.")
            }
            // The change is no longer the one the person agreed to throw away: nothing is done.
            guard GitActions.discardTrashes(current) == GitActions.discardTrashes(change) else { return }
            try GitActions.discard(current, in: repo, launcher: launcher, trash: trash)
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

    /// Asks before `change` is thrown away. An untracked file goes to the Trash, and the question
    /// says so. Escape answers Cancel.
    public func confirmDiscard(_ change: GitChange, prompter: Prompter) async -> Bool {
        let name = (change.path as NSString).lastPathComponent
        let why = change.letter == .untracked ? "It isn’t in git yet" : "It was only marked to be added"
        let prompt = GitActions.discardTrashes(change)
            ? AlertPrompt(message: "Move “\(name)” to the Trash?",
                          detail: "\(why), so discarding it moves the file to the Trash.",
                          buttons: ["Move to Trash", "Cancel"], defaultDeletes: true)
            : AlertPrompt(message: "Discard changes to “\(name)”?", detail: "This can’t be undone.",
                          buttons: ["Discard Changes", "Cancel"], defaultDeletes: true)
        return await prompter.ask(prompt).confirmed
    }

    /// Switches a project's folder to `branch`, asking what `flow` asks, after what is queued for
    /// the repository; then reads it again. `busyTask` gives a task working in the folder, read
    /// just before the flow asks about it. A
    /// Cancel is no problem; any other failure is the section's problem until the next action.
    /// A task's worktree is not switched.
    public func switchBranch(_ repo: GitRepoID, to branch: String, flow: BranchSwitchFlow,
                             busyTask: @escaping @MainActor () -> String?) async {
        guard case .project = repo, let epoch = epochs[repo] else { return }
        await enqueue(repo) { [weak self] in
            await self?.runSwitch(repo, to: branch, flow: flow, busyTask: busyTask, epoch: epoch)
        }.value
    }

    private func runSwitch(_ id: GitRepoID, to branch: String, flow: BranchSwitchFlow,
                           busyTask: @MainActor () -> String?, epoch: Int) async {
        await busy(id, epoch: epoch) { repo in
            let project = Project(id: repo.projectId, name: repo.title, path: repo.path)
            do {
                _ = try await flow.switchProject(project, to: branch, busyTask: busyTask,
                                                 stashLabel: "switching to “\(branch)”", offerOtherWorktree: false)
                return nil
            } catch is CreationDeclined {
                return nil
            } catch {
                return Self.problem(error)
            }
        }
    }

    // -- commit messages ------------------------------------------------------------------

    public func commitMessage(_ repo: GitRepoID) -> String { drafts[repo]?.text ?? "" }

    public func setCommitMessage(_ text: String, for repo: GitRepoID) {
        guard repos[repo] != nil, commitMessage(repo) != text else { return }
        draft(repo).text = text
    }

    /// The repository's draft, which its commit field observes. Typing changes it and not
    /// `sections`, so only that field redraws.
    public func draft(_ repo: GitRepoID) -> CommitDraft {
        if let draft = drafts[repo] { return draft }
        let draft = CommitDraft()
        drafts[repo] = draft
        return draft
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
                guard let repo = repos[.task(task)], repo.projectId == project, Self.isShown(repo) else { return nil }
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
