import Combine
import XCTest
@testable import ShellforgeCore
import ShellforgeTestSupport
@testable import ShellforgeUI

private final class FakeWatcher: FolderWatching, @unchecked Sendable {
    let path: String
    private let lock = NSLock()
    private var handler: (@Sendable ([String]) -> Void)?
    private var stopped = false
    init(_ path: String) { self.path = path }
    func watch(_ path: String, onChange: @escaping @Sendable () -> Void) { watch(path, onChanges: { _ in onChange() }) }
    func watch(_ path: String, onChanges: @escaping @Sendable ([String]) -> Void) { lock.withLock { handler = onChanges } }
    /// Keeps its handler, so a test can fire a late event after the stop.
    func stop() { lock.withLock { stopped = true } }
    var isStopped: Bool { lock.withLock { stopped } }
    func fire(_ changes: [String] = []) { lock.withLock { handler }?(changes) }
}

/// Repositories in a scratch folder, with a hermetic git: no user or system config, a fixed identity.
private struct Scratch {
    let root: String
    let launcher: CommandLauncher

    init() throws {
        root = TestScratch.root.appendingPathComponent("shellforge-gitmodel-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let env = ["PATH": "/usr/bin:/bin", "HOME": root, "GIT_CONFIG_NOSYSTEM": "1",
                   "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]
        launcher = CommandLauncher { ResolvedEnvironment(variables: env, source: .loginShell("/bin/sh")) }
    }

    /// A repository with one commit on `main`, as a project.
    func project(_ name: String) throws -> Project {
        let path = "\(root)/\(name)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: path)
        try git(["commit", "-q", "--allow-empty", "-m", "first"], in: path)
        return Project(name: name, path: path)
    }

    /// A task's worktree of `project`, at `.worktrees/<slug>` on a new branch.
    func task(_ title: String, slug: String, branch: String, of project: Project) throws -> TaskItem {
        let path = "\(project.path)/.worktrees/\(slug)"
        try git(["worktree", "add", "-q", "-b", branch, path], in: project.path)
        return TaskItem(projectId: project.id, title: title, branch: branch, worktreePath: path, baseBranch: "main")
    }

    func write(_ name: String, in folder: String) throws {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "x\n".write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func git(_ args: [String], in directory: String) throws -> String {
        let out = try launcher.run("git", ["-C", directory] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reads with real git, counting reads per path; can hold the next read of a path until released.
private final class Reader: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var holds: [String: DispatchSemaphore] = [:]
    private let reached = DispatchSemaphore(value: 0)

    func read(_ path: String, _ launcher: CommandLauncher) throws -> GitStatus {
        let gate: DispatchSemaphore? = lock.withLock {
            counts[path, default: 0] += 1
            return holds.removeValue(forKey: path)
        }
        if let gate {
            reached.signal()
            gate.wait()
        }
        return try GitStatus.read(path, launcher: launcher)
    }
    func count(_ path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    func holdNext(_ path: String) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock { holds[path] = gate }
        return gate
    }
    func waitUntilHeld() async { await BackgroundWork.run { self.reached.wait() } }
}

/// An action that records when it starts and ends, and holds the first one until released.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var holding = true
    private let hold = DispatchSemaphore(value: 0)
    private let reached = DispatchSemaphore(value: 0)

    func act(_ action: GitAction) {
        let name: String
        switch action {
        case .stage: name = "stage"
        case .push: name = "push"
        default: name = "other"
        }
        let held: Bool = lock.withLock {
            log.append("start \(name)")
            defer { holding = false }
            return holding
        }
        if held {
            reached.signal()
            hold.wait()
        }
        lock.withLock { log.append("end \(name)") }
    }
    var events: [String] { lock.withLock { log } }
    func release() { hold.signal() }
    func waitUntilHeld() async { await BackgroundWork.run { self.reached.wait() } }
}

@MainActor
final class GitModelTests: XCTestCase {
    private func model(_ scratch: Scratch, _ projects: [Project], tasks: [TaskItem] = [], reader: Reader = Reader(),
                       act: GitModel.Act? = nil, watchers: @escaping (FakeWatcher) -> Void = { _ in }) -> GitModel {
        GitModel(projects: projects, tasks: tasks, launcher: scratch.launcher,
                 watcher: { let w = FakeWatcher($0); watchers(w); return w },
                 read: { try reader.read($0, $1) },
                 act: act ?? { try GitModel.run($0, in: $1, message: $2, launcher: $3) })
    }

    private func status(_ section: GitSection?) -> GitStatus? {
        guard case .status(let status) = section?.state else { return nil }
        return status
    }

    func testAChangeRefreshesThatRepositoryOnly() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo"), acme = try scratch.project("acme-web")
        let reader = Reader()
        var made: [String: FakeWatcher] = [:]
        let git = model(scratch, [demo, acme], reader: reader, watchers: { made[$0.path] = $0 })
        await git.settled()
        XCTAssertEqual(git.sections.map(\.title), ["demo", "acme-web"])
        XCTAssertNotNil(status(git.sections.first))
        let before = (reader.count(demo.path), reader.count(acme.path))
        try scratch.write("src/app.ts", in: demo.path)
        made[demo.path]!.fire(["src/app.ts"])
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before.0 + 1)
        XCTAssertEqual(reader.count(acme.path), before.1)
        XCTAssertEqual(status(git.sections.first)?.unstaged.map(\.path), ["src/app.ts"])
    }

    func testATaskWithChangesIsListedUnderItsProject() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo"), acme = try scratch.project("acme-web")
        let task = try scratch.task("Login page", slug: "feature-login-page", branch: "feature/login-page", of: demo)
        try scratch.write("src/app.ts", in: task.worktreePath)
        let reader = Reader()
        var made: [String: FakeWatcher] = [:]
        let git = model(scratch, [demo, acme], tasks: [task], reader: reader, watchers: { made[$0.path] = $0 })
        await git.settled()
        XCTAssertEqual(git.sections.map(\.title), ["demo", "acme-web"])
        XCTAssertEqual(git.sections[0].tasks.map(\.title), ["Login page"])
        XCTAssertEqual(git.sections[0].tasks.first?.id, .task(task.id))
        XCTAssertEqual(git.sections[0].tasks.first?.path, task.worktreePath)
        XCTAssertTrue(git.sections[1].tasks.isEmpty)
        XCTAssertEqual(status(git.sections[0])?.hasChanges, false, "the task's files are not the project's")

        // Staging in the task changes its index in the project's .git: the project's watcher sees it.
        try scratch.git(["add", "src/app.ts"], in: task.worktreePath)
        let projectReads = reader.count(demo.path)
        made[demo.path]!.fire([".git/worktrees/feature-login-page/index"])
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), projectReads)
        XCTAssertEqual(status(git.sections[0].tasks.first)?.staged.map(\.path), ["src/app.ts"])
    }

    func testAMovedUpstreamRefreshesTheTasksAheadAndBehind() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let origin = "\(scratch.root)/origin.git"
        try scratch.git(["init", "-q", "--bare", "-b", "main", origin], in: scratch.root)
        try scratch.git(["remote", "add", "origin", origin], in: demo.path)
        let task = try scratch.task("Login page", slug: "feature-login-page", branch: "feature/login-page", of: demo)
        try scratch.git(["push", "-q", "-u", "origin", "feature/login-page"], in: task.worktreePath)
        try scratch.write("src/app.ts", in: task.worktreePath)
        var made: [String: FakeWatcher] = [:]
        let git = model(scratch, [demo], tasks: [task], watchers: { made[$0.path] = $0 })
        await git.settled()
        XCTAssertEqual(status(git.sections[0].tasks.first)?.behind, 0)

        // A fetch moves the upstream: one more commit on it, as the project's refs record it.
        let tip = try scratch.git(["commit-tree", "feature/login-page^{tree}", "-p", "feature/login-page", "-m", "remote"], in: demo.path)
        try scratch.git(["update-ref", "refs/remotes/origin/feature/login-page", tip], in: demo.path)
        made[demo.path]!.fire([".git/refs/remotes/origin/feature/login-page"])
        await git.settled()
        XCTAssertEqual(status(git.sections[0].tasks.first)?.behind, 1)
    }

    func testATaskWhoseWorktreeNameClashesIsFoundByItsGitFile() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        // Another worktree with the same folder name takes `feature-login-page` in .git/worktrees/.
        try scratch.git(["worktree", "add", "-q", "-b", "feature/other", "\(scratch.root)/elsewhere/feature-login-page"], in: demo.path)
        let task = try scratch.task("Login page", slug: "feature-login-page", branch: "feature/login-page", of: demo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(demo.path)/.git/worktrees/feature-login-page1"))
        try scratch.write("src/app.ts", in: task.worktreePath)
        var made: [String: FakeWatcher] = [:]
        let git = model(scratch, [demo], tasks: [task], watchers: { made[$0.path] = $0 })
        await git.settled()
        XCTAssertEqual(status(git.sections[0].tasks.first)?.staged, [])
        try scratch.git(["add", "src/app.ts"], in: task.worktreePath)
        made[demo.path]!.fire([".git/worktrees/feature-login-page1/index"])
        await git.settled()
        XCTAssertEqual(status(git.sections[0].tasks.first)?.staged.map(\.path), ["src/app.ts"])
    }

    func testATaskWithoutChangesIsNot() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let clean = try scratch.task("Login page", slug: "feature-login-page", branch: "feature/login-page", of: demo)
        let gone = TaskItem(projectId: demo.id, title: "Checkout", branch: "feature/checkout",
                            worktreePath: "\(demo.path)/.worktrees/feature-checkout", baseBranch: "main")
        let git = model(scratch, [demo], tasks: [clean, gone])
        await git.settled()
        XCTAssertEqual(git.sections.map(\.title), ["demo"])
        XCTAssertTrue(git.sections[0].tasks.isEmpty)
    }

    /// A clean task whose branch is ahead of its upstream is listed: it has commits to push.
    func testATaskAheadOfItsUpstreamIsListed() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let origin = "\(scratch.root)/origin.git"
        try scratch.git(["init", "-q", "--bare", "-b", "main", origin], in: scratch.root)
        try scratch.git(["remote", "add", "origin", origin], in: demo.path)
        let task = try scratch.task("Login page", slug: "feature-login-page", branch: "feature/login-page", of: demo)
        try scratch.git(["push", "-q", "-u", "origin", "feature/login-page"], in: task.worktreePath)
        let git = model(scratch, [demo], tasks: [task])
        await git.settled()
        XCTAssertTrue(git.sections[0].tasks.isEmpty, "pushed and clean")
        try scratch.git(["commit", "-q", "--allow-empty", "-m", "login"], in: task.worktreePath)
        await git.refresh(.task(task.id))
        XCTAssertEqual(git.sections[0].tasks.map(\.title), ["Login page"])
    }

    /// A clean task with no upstream is listed while it has commits its base branch lacks.
    func testATaskWithUnpublishedCommitsIsListed() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let task = try scratch.task("Login page", slug: "feature-login-page", branch: "feature/login-page", of: demo)
        try scratch.git(["commit", "-q", "--allow-empty", "-m", "login"], in: task.worktreePath)
        let git = model(scratch, [demo], tasks: [task])
        await git.settled()
        XCTAssertEqual(git.sections[0].tasks.map(\.title), ["Login page"])
        XCTAssertEqual(status(git.sections[0].tasks.first)?.hasChanges, false)
    }

    /// A Review task without a merge request has no base branch: its commits can't be counted, so
    /// it stays listed rather than hide work that isn't published.
    func testATaskWithoutABaseBranchShowsAfterACommit() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        var task = try scratch.task("Login page", slug: "feature-login-page", branch: "feature/login-page", of: demo)
        task.baseBranch = ""
        try scratch.write("src/app.ts", in: task.worktreePath)
        try scratch.git(["add", "src/app.ts"], in: task.worktreePath)
        let git = model(scratch, [demo], tasks: [task])
        await git.settled()
        try scratch.git(["commit", "-q", "-m", "login"], in: task.worktreePath)
        await git.refresh(.task(task.id))
        XCTAssertEqual(git.sections[0].tasks.map(\.title), ["Login page"])
        XCTAssertEqual(status(git.sections[0].tasks.first)?.hasChanges, false)
    }

    /// A Project folder task works in its project's folder: no second section, watcher or queue.
    func testAProjectFolderTaskIsNotASecondSection() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let task = TaskItem(projectId: demo.id, title: "Login page", branch: "main", worktreePath: demo.path, baseBranch: "main")
        try scratch.write("src/app.ts", in: demo.path)
        var watched: [String] = []
        let git = model(scratch, [demo], tasks: [task], watchers: { watched.append($0.path) })
        await git.settled()
        XCTAssertEqual(watched, [demo.path])
        XCTAssertEqual(git.sections.map(\.title), ["demo"])
        XCTAssertTrue(git.sections[0].tasks.isEmpty)
        XCTAssertEqual(status(git.sections[0])?.unstaged.map(\.path), ["src/app.ts"])
    }

    /// The panel showed staged files, and they were unstaged elsewhere before Commit ran: nothing is
    /// committed, rather than every change.
    func testACommitOfStagedFilesCommitsNothingOnceNoneAreStaged() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        try scratch.write("src/app.ts", in: demo.path)
        let git = model(scratch, [demo])
        await git.settled()
        let id = GitRepoID.project(demo.id)
        let head = try scratch.git(["rev-parse", "HEAD"], in: demo.path)
        git.setCommitMessage("Add the login page", for: id)
        await git.perform(.commit(expectsStaged: true), in: id)
        XCTAssertEqual(git.sections.first?.problem, "The staged files changed. Check them and commit again.")
        XCTAssertEqual(try scratch.git(["rev-parse", "HEAD"], in: demo.path), head)
        XCTAssertEqual(git.commitMessage(id), "Add the login page", "the message is kept")
        XCTAssertEqual(status(git.sections.first)?.unstaged.map(\.path), ["src/app.ts"])
    }

    /// The panel showed nothing staged, so Commit was to take every change; an agent staged one
    /// file before it ran. Committing only that file is not what the panel offered: nothing is
    /// committed, and the person is asked to look again.
    func testCommitAllRefusesWhenSomethingWasStagedMeanwhile() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        try scratch.write("src/app.ts", in: demo.path)
        try scratch.write("src/login.ts", in: demo.path)
        let git = model(scratch, [demo])
        await git.settled()
        let id = GitRepoID.project(demo.id)
        let head = try scratch.git(["rev-parse", "HEAD"], in: demo.path)
        try scratch.git(["add", "src/login.ts"], in: demo.path)
        git.setCommitMessage("Add the login page", for: id)
        await git.perform(.commit(expectsStaged: false), in: id)
        XCTAssertEqual(git.sections.first?.problem, "The staged files changed. Check them and commit again.")
        XCTAssertEqual(try scratch.git(["rev-parse", "HEAD"], in: demo.path), head)
        XCTAssertEqual(git.commitMessage(id), "Add the login page", "the message is kept")
        XCTAssertEqual(status(git.sections.first)?.staged.map(\.path), ["src/login.ts"])
    }

    /// A clean task whose action failed stays listed, so its problem is seen.
    func testATaskWithAProblemIsListed() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let task = try scratch.task("Login page", slug: "feature-login-page", branch: "feature/login-page", of: demo)
        let git = model(scratch, [demo], tasks: [task])
        await git.settled()
        XCTAssertTrue(git.sections[0].tasks.isEmpty)
        await git.perform(.push, in: .task(task.id))
        XCTAssertEqual(git.sections[0].tasks.map(\.title), ["Login page"], "a push with no origin failed out of sight")
        XCTAssertNotNil(git.sections[0].tasks.first?.problem)
    }

    /// Typing a message changes its draft, not the model's sections.
    func testTypingAMessageDoesNotRepublishTheSections() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let git = model(scratch, [demo])
        await git.settled()
        let id = GitRepoID.project(demo.id)
        var changes = 0
        let watch = git.objectWillChange.sink { changes += 1 }
        var drafted = 0
        let draftWatch = git.draft(id).objectWillChange.sink { drafted += 1 }
        git.setCommitMessage("Add the login page", for: id)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(drafted, 1)
        XCTAssertEqual(git.draft(id).text, "Add the login page")
        _ = (watch, draftWatch)
    }

    /// The workspace's projects and tasks reach the model as the host wires it: `follow`.
    func testTheModelFollowsTheWorkspace() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: URL(fileURLWithPath: "\(scratch.root)/data")))
        let git = model(scratch, [])
        git.follow(document.$workspace)
        XCTAssertTrue(git.sections.isEmpty)
        try document.update { $0.projects.append(demo) }
        await git.settled()
        XCTAssertEqual(git.sections.map(\.title), ["demo"])
        try document.update { $0.projects.removeAll() }
        XCTAssertTrue(git.sections.isEmpty)
    }

    func testActionsOnOneRepositoryRunOneAtATime() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let gate = Gate()
        let git = model(scratch, [demo], act: { action, _, _, _ in gate.act(action) })
        await git.settled()
        let first = Task { await git.perform(.stage(["src/app.ts"]), in: .project(demo.id)) }
        await gate.waitUntilHeld()
        XCTAssertEqual(git.sections.first?.busy, true)
        var second: Task<Void, Never>?
        await withCheckedContinuation { (queued: CheckedContinuation<Void, Never>) in
            git.enqueued = { _ in
                git.enqueued = nil
                queued.resume()
            }
            second = Task { await git.perform(.push, in: .project(demo.id)) }
        }
        XCTAssertEqual(gate.events, ["start stage"], "the second action started while the first ran")
        gate.release()
        await first.value
        await second?.value
        XCTAssertEqual(gate.events, ["start stage", "end stage", "start push", "end push"])
        XCTAssertEqual(git.sections.first?.busy, false)
    }

    func testEventsDuringAnActionMakeOneRefreshAfterIt() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let gate = Gate(), reader = Reader()
        var made: [String: FakeWatcher] = [:]
        let git = model(scratch, [demo], reader: reader, act: { action, _, _, _ in gate.act(action) }, watchers: { made[$0.path] = $0 })
        await git.settled()
        let before = reader.count(demo.path)
        let action = Task { await git.perform(.stage(["src/app.ts"]), in: .project(demo.id)) }
        await gate.waitUntilHeld()
        for _ in 0..<3 { made[demo.path]!.fire(["src/app.ts"]) }
        await git.eventsDelivered()
        gate.release()
        await action.value
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before + 1)
    }

    func testCommitClearsTheMessage() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        try scratch.write("src/app.ts", in: demo.path)
        let git = model(scratch, [demo])
        await git.settled()
        let id = GitRepoID.project(demo.id)
        git.setCommitMessage("Add the login page", for: id)
        XCTAssertEqual(git.commitMessage(id), "Add the login page")
        await git.perform(.commit(expectsStaged: false), in: id)
        XCTAssertEqual(git.commitMessage(id), "")
        XCTAssertNil(git.sections.first?.problem)
        XCTAssertEqual(status(git.sections.first)?.hasChanges, false)
        XCTAssertEqual(try scratch.git(["log", "-1", "--format=%s"], in: demo.path), "Add the login page")
    }

    func testAFailedActionShowsItsProblem() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let git = model(scratch, [demo])
        await git.settled()
        let id = GitRepoID.project(demo.id)
        await git.perform(.push, in: id)
        XCTAssertNotNil(git.sections.first?.problem, "a push with no origin failed quietly")
        XCTAssertEqual(git.sections.first?.busy, false)
        try scratch.write("src/app.ts", in: demo.path)
        await git.perform(.stage(["src/app.ts"]), in: id)
        XCTAssertNil(git.sections.first?.problem)
        XCTAssertEqual(status(git.sections.first)?.staged.map(\.path), ["src/app.ts"])
    }

    func testARemovedProjectDoesNotReappear() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo"), acme = try scratch.project("acme-web")
        let reader = Reader()
        let gate = reader.holdNext(demo.path)
        var made: [String: FakeWatcher] = [:]
        let git = model(scratch, [demo, acme], reader: reader, watchers: { made[$0.path] = $0 })
        await reader.waitUntilHeld()
        git.update(projects: [acme], tasks: [])
        XCTAssertEqual(git.sections.map(\.title), ["acme-web"])
        XCTAssertTrue(made[demo.path]!.isStopped)
        gate.signal()
        await git.settled()
        XCTAssertEqual(git.sections.map(\.title), ["acme-web"])
        made[demo.path]!.fire()
        await git.settled()
        XCTAssertEqual(git.sections.map(\.title), ["acme-web"])
        await git.perform(.stage(["src/app.ts"]), in: .project(demo.id))
        XCTAssertEqual(git.sections.map(\.title), ["acme-web"])
    }
}

// -- while hidden, and what git ignores ----------------------------------------------------

extension GitModelTests {
    /// No window shows the panel: a change marks the repository and reads nothing. Shown again,
    /// the marked repository is read once, the others not at all.
    func testAHiddenPanelRunsNoGit() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo"), acme = try scratch.project("acme-web")
        let reader = Reader()
        var made: [String: FakeWatcher] = [:]
        let holder = GitHolder { self.model(scratch, [demo, acme], reader: reader, watchers: { made[$0.path] = $0 }) }
        let git = holder.model
        var viewer: PanelViewer? = holder.register()
        await git.settled()
        let before = (reader.count(demo.path), reader.count(acme.path))

        viewer?.release()
        XCTAssertFalse(git.isShown)
        try scratch.write("src/app.ts", in: demo.path)
        made[demo.path]!.fire(["src/app.ts"])
        made[demo.path]!.fire(["src/app.ts"])
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before.0, "nothing is read while no window shows the panel")
        XCTAssertNil(status(git.sections.first)?.unstaged.first)

        viewer = holder.register()
        XCTAssertTrue(git.isShown)
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before.0 + 1, "the marked repository is read once")
        XCTAssertEqual(reader.count(acme.path), before.1, "one that did not change is not")
        XCTAssertEqual(status(git.sections.first)?.unstaged.map(\.path), ["src/app.ts"])

        // A window that closes without saying its panel disappeared lets go all the same.
        viewer = nil
        XCTAssertEqual(holder.viewerCount, 0)
        XCTAssertFalse(git.isShown)
    }

    /// Two windows show the panel: hiding it in one keeps it live for the other.
    func testThePanelStaysLiveWhileAnyWindowShowsIt() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        let reader = Reader()
        var made: [String: FakeWatcher] = [:]
        let holder = GitHolder { self.model(scratch, [demo], reader: reader, watchers: { made[$0.path] = $0 }) }
        let git = holder.model
        let first = holder.register(), second = holder.register()
        await git.settled()
        first.release()
        first.release()   // released once only
        XCTAssertEqual(holder.viewerCount, 1)
        let before = reader.count(demo.path)
        made[demo.path]!.fire(["src/app.ts"])
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before + 1)
        second.release()
        XCTAssertFalse(git.isShown)
    }

    /// A build writing under an ignored folder reads nothing; a tracked file beside it still does,
    /// and a changed `.gitignore` lists the ignored folders again.
    func testIgnoredBuildOutputTriggersNothing() async throws {
        let scratch = try Scratch()
        let demo = try scratch.project("demo")
        try "build/\nnode_modules/\n".write(toFile: demo.path + "/.gitignore", atomically: true, encoding: .utf8)
        try scratch.write("build/out/app.o", in: demo.path)
        try scratch.write("node_modules/left-pad/index.js", in: demo.path)
        let reader = Reader()
        var made: [String: FakeWatcher] = [:]
        let git = model(scratch, [demo], reader: reader, watchers: { made[$0.path] = $0 })
        await git.settled()
        let before = reader.count(demo.path)

        made[demo.path]!.fire(["build/out/app.o", "build/out", "node_modules/left-pad/index.js"])
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before, "only ignored paths changed")

        made[demo.path]!.fire(["build/out/app.o", "src/app.ts"])
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before + 1, "a path git does not ignore counts")

        // build/ is no longer ignored: the rules are listed again, and its changes count.
        try "node_modules/\n".write(toFile: demo.path + "/.gitignore", atomically: true, encoding: .utf8)
        made[demo.path]!.fire([".gitignore"])
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before + 2)
        made[demo.path]!.fire(["build/out/app.o"])
        await git.settled()
        XCTAssertEqual(reader.count(demo.path), before + 3)
    }
}
