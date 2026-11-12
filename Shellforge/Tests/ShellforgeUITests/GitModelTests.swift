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
    func watch(_ path: String, onChange: @escaping @Sendable () -> Void) { watch(path) { _ in onChange() } }
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
        await git.perform(.commit, in: id)
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
