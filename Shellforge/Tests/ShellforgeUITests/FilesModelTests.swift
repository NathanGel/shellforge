import Combine
import XCTest
@testable import ShellforgeCore
@testable import ShellforgeTestSupport
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
    /// No paths: the stream could not say what changed.
    func fire(_ changes: [String] = []) { lock.withLock { handler }?(changes) }
}

/// Answers listings, counts them per path, and can hold the next one until the test lets it go.
/// `readsDisk` lists the real folder instead of answering.
private final class Lister: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var offMain = true
    private var answer = ["src/app.ts", "README.md"]
    private var hold: DispatchSemaphore?
    private let reached = DispatchSemaphore(value: 0)
    private let readsDisk: Bool

    init(readsDisk: Bool = false) { self.readsDisk = readsDisk }

    func list(_ path: String, _ launcher: CommandLauncher) -> ProjectFiles.Listing {
        let (paths, gate): ([String], DispatchSemaphore?) = lock.withLock {
            counts[path, default: 0] += 1
            if Thread.isMainThread { offMain = false }
            defer { hold = nil }
            return (answer, hold)
        }
        let listing = readsDisk ? ProjectFiles.list(path, launcher: launcher) : .git(paths)
        if let gate {
            reached.signal()
            gate.wait()
        }
        return listing
    }
    func count(_ path: String) -> Int { lock.withLock { counts[path] ?? 0 } }
    var ranOffMain: Bool { lock.withLock { offMain } }
    func answer(_ paths: [String]) { lock.withLock { answer = paths } }
    /// The next listing reads its answer, then waits for `release`.
    func holdNext() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.withLock { hold = gate }
        return gate
    }
    /// Returns once a held listing has started.
    func waitUntilHeld() async { await BackgroundWork.run { self.reached.wait() } }
}

@MainActor
final class FilesModelTests: XCTestCase {
    private let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin"], source: .loginShell("/bin/zsh")) })
    private let demo = Project(name: "demo", path: "/work/demo")
    private let acme = Project(name: "acme-web", path: "/work/acme-web")

    private func model(_ projects: [Project], defaults: UserDefaults = ScratchDefaults.make(), lister: Lister = Lister(),
                       ignored: IgnoredPaths = .none, watchers: @escaping (FakeWatcher) -> Void = { _ in }) -> FilesModel {
        FilesModel(projects: projects, launcher: launcher, defaults: defaults,
                   watcher: { let w = FakeWatcher($0); watchers(w); return w },
                   list: { path, launcher in lister.list(path, launcher) },
                   ignored: { _, _ in ignored })
    }

    func testAChangeRefreshesThatProjectOnly() async {
        let lister = Lister()
        var made: [String: FakeWatcher] = [:]
        let files = model([demo, acme], lister: lister) { made[$0.path] = $0 }
        await files.refresh(project: demo.id)
        await files.refresh(project: acme.id)
        await files.settled()
        let before = (lister.count(demo.path), lister.count(acme.path))
        made[demo.path]!.fire()
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before.0 + 1)
        XCTAssertEqual(lister.count(acme.path), before.1)
    }

    func testOpenFoldersAreRememberedPerProject() {
        let defaults = ScratchDefaults.make()
        let first = model([demo, acme], defaults: defaults)
        XCTAssertFalse(first.isOpen(project: demo.id, folder: "src"))
        first.toggle(project: demo.id, folder: "src")
        let second = model([demo, acme], defaults: defaults)
        XCTAssertTrue(second.isOpen(project: demo.id, folder: "src"))
        XCTAssertFalse(second.isOpen(project: acme.id, folder: "src"))
        second.toggle(project: demo.id, folder: "src")
        XCTAssertFalse(model([demo], defaults: defaults).isOpen(project: demo.id, folder: "src"))
    }

    func testASectionIsOpenUntilItIsClosed() {
        let defaults = ScratchDefaults.make()
        let files = model([demo], defaults: defaults)
        XCTAssertTrue(files.isOpen(project: demo.id, folder: ""))
        files.toggle(project: demo.id, folder: "")
        XCTAssertFalse(model([demo], defaults: defaults).isOpen(project: demo.id, folder: ""))
    }

    func testARemovedProjectStopsWatching() {
        var made: [String: FakeWatcher] = [:]
        let files = model([demo, acme]) { made[$0.path] = $0 }
        files.update(projects: [acme])
        XCTAssertTrue(made[demo.path]!.isStopped)
        XCTAssertFalse(made[acme.path]!.isStopped)
        XCTAssertEqual(files.sections.map(\.project.name), ["acme-web"])
    }

    func testUpdateKeepsOrderAndAddsNewProjects() async {
        let lister = Lister()
        let files = model([demo], lister: lister)
        await files.settled()
        files.update(projects: [acme, demo])
        await files.settled()
        XCTAssertEqual(files.sections.map(\.project.name), ["acme-web", "demo"])
        XCTAssertEqual(lister.count(demo.path), 1, "a project still present is not listed again")
        XCTAssertEqual(lister.count(acme.path), 1)
    }

    func testAMissingFolderIsReported() async {
        let gone = Project(name: "demo", path: NSTemporaryDirectory() + "no-such-\(UUID().uuidString)")
        let files = FilesModel(projects: [gone], launcher: launcher, defaults: ScratchDefaults.make(), watcher: { FakeWatcher($0) })
        await files.refresh(project: gone.id)
        XCTAssertEqual(files.sections.first?.state, FilesSection.State.missing)
    }

    func testRefreshRunsOffTheMainActor() async {
        let lister = Lister()
        let files = model([demo], lister: lister)
        await files.refresh(project: demo.id)
        XCTAssertTrue(lister.ranOffMain)
        XCTAssertEqual(files.sections.first?.state, .tree(FileTree.build(["src/app.ts", "README.md"])))
    }

    func testAPlainFolderLoadsOneLevelAtATime() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("src/app.ts"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "demo", path: root.path)
        let files = FilesModel(projects: [project], launcher: launcher, defaults: ScratchDefaults.make(), watcher: { FakeWatcher($0) })
        await files.refresh(project: project.id)
        guard case .tree(let top) = files.sections[0].state else { return XCTFail("no tree") }
        XCTAssertNil(top.first?.children)
        await files.loadChildren(project: project.id, folder: "src")
        guard case .tree(let loaded) = files.sections[0].state else { return XCTFail("no tree") }
        XCTAssertEqual(loaded.first?.children?.map { $0.path }, ["src/app.ts"])
    }

    func testARemovedProjectDoesNotReappear() async {
        let lister = Lister()
        let files = model([demo, acme], lister: lister)
        await files.settled()
        let gate = lister.holdNext()
        let held = Task { await files.refresh(project: demo.id) }
        await lister.waitUntilHeld()
        files.update(projects: [acme])
        gate.signal()
        await held.value
        XCTAssertEqual(files.sections.map(\.project.name), ["acme-web"])
        files.update(projects: [demo, acme])   // added again: its section starts from nothing
        XCTAssertEqual(files.sections.first?.state, FilesSection.State.loading)
        await files.settled()
        XCTAssertEqual(files.sections.first?.state, .tree(FileTree.build(["src/app.ts", "README.md"])))
    }

    func testAStaleResultDoesNotOverwriteANewerOne() async {
        let lister = Lister()
        let files = model([demo], lister: lister)
        await files.settled()
        lister.answer(["old.txt"])
        let gate = lister.holdNext()
        let first = Task { await files.refresh(project: demo.id) }
        await lister.waitUntilHeld()
        lister.answer(["src/app.ts"])
        await files.refresh(project: demo.id)
        gate.signal()
        await first.value
        XCTAssertEqual(files.sections.first?.state, .tree(FileTree.build(["src/app.ts"])))
    }

    func testEventsDuringARefreshCostOneMoreRefresh() async {
        let lister = Lister()
        var made: [String: FakeWatcher] = [:]
        let files = model([demo], lister: lister) { made[$0.path] = $0 }
        await files.settled()
        let before = lister.count(demo.path)
        let gate = lister.holdNext()
        made[demo.path]!.fire()
        await files.eventsDelivered()
        await lister.waitUntilHeld()
        for _ in 0..<3 { made[demo.path]!.fire() }
        await files.eventsDelivered()
        gate.signal()
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before + 2)
    }

    func testALateEventForARemovedProjectIsIgnored() async {
        let lister = Lister()
        var made: [String: FakeWatcher] = [:]
        let files = model([demo, acme], lister: lister) { made[$0.path] = $0 }
        await files.settled()
        let before = lister.count(demo.path)
        files.update(projects: [acme])
        made[demo.path]!.fire()
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before)
    }

    func testAMovedFolderRestartsItsWatcherAndReloads() async {
        let lister = Lister()
        var made: [String: FakeWatcher] = [:]
        let files = model([demo], lister: lister) { made[$0.path] = $0 }
        await files.settled()
        var moved = demo
        moved.path = "/work/demo-2"
        files.update(projects: [moved])
        XCTAssertTrue(made[demo.path]!.isStopped)
        await files.settled()
        XCTAssertNotNil(made[moved.path])
        XCTAssertEqual(lister.count(moved.path), 1)
        XCTAssertEqual(files.sections.first?.project.path, "/work/demo-2")
    }

    func testARefreshKeepsTheOpenFoldersOfAPlainFolderLoaded() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src/lib"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "demo", path: root.path)
        let files = FilesModel(projects: [project], launcher: launcher, defaults: ScratchDefaults.make(), watcher: { FakeWatcher($0) })
        files.toggle(project: project.id, folder: "src")
        await files.refresh(project: project.id)
        guard case .tree(let top) = files.sections[0].state else { return XCTFail("no tree") }
        XCTAssertEqual(top.first?.children?.map { $0.path }, ["src/lib"])
    }

    func testHandedEventsAreNotKept() async {
        var made: [String: FakeWatcher] = [:]
        let files = model([demo]) { made[$0.path] = $0 }
        for _ in 0..<100 { made[demo.path]!.fire() }
        await files.settled()
        XCTAssertEqual(files.pendingHops, 0)
    }

    /// A plain folder with `a/b/c.txt`.
    private func nestedFolder() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("a/b/c.txt"), atomically: true, encoding: .utf8)
        return root
    }

    private func children(of folder: String, in files: FilesModel) -> [String]? {
        guard case .tree(let nodes) = files.sections[0].state else { return nil }
        var level = nodes
        var found: FileNode?
        for part in folder.split(separator: "/") {
            found = level.first { $0.name == part }
            level = found?.children ?? []
        }
        return found?.children?.map(\.path)
    }

    func testReopeningAParentLoadsItsOpenChildren() async throws {
        let root = try nestedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "demo", path: root.path)
        let files = model([project], lister: Lister(readsDisk: true))
        await files.settled()
        files.toggle(project: project.id, folder: "a")
        files.toggle(project: project.id, folder: "a/b")
        await files.refresh(project: project.id)
        XCTAssertEqual(children(of: "a/b", in: files), ["a/b/c.txt"])
        files.toggle(project: project.id, folder: "a")   // closed
        try "y".write(to: root.appendingPathComponent("a/d.txt"), atomically: true, encoding: .utf8)
        await files.refresh(project: project.id)
        XCTAssertNil(children(of: "a", in: files), "a closed folder is not read")
        files.toggle(project: project.id, folder: "a")   // open again
        await files.loadChildren(project: project.id, folder: "a")
        XCTAssertEqual(children(of: "a/b", in: files), ["a/b/c.txt"], "the open child was left empty")
    }

    func testAFolderOpenedDuringARefreshStaysLoaded() async throws {
        let root = try nestedFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "demo", path: root.path)
        let lister = Lister(readsDisk: true)
        let files = model([project], lister: lister)
        await files.settled()
        // The listing changes, so the late one is applied.
        try "x".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let gate = lister.holdNext()
        let held = Task { await files.refresh(project: project.id) }
        await lister.waitUntilHeld()   // listed before `a` was opened
        files.toggle(project: project.id, folder: "a")
        await files.loadChildren(project: project.id, folder: "a")
        XCTAssertEqual(children(of: "a", in: files), ["a/b"])
        gate.signal()
        await held.value
        await files.settled()
        XCTAssertEqual(children(of: "a", in: files), ["a/b"], "the late listing left the open folder empty")
    }

    func testARefreshThatChangesNothingPublishesNothing() async {
        let files = model([demo])
        await files.settled()
        var published = 0
        let watching = files.$sections.dropFirst().sink { _ in published += 1 }
        await files.refresh(project: demo.id)
        watching.cancel()
        XCTAssertEqual(published, 0)
    }
}

// -- while hidden, what git ignores, and what is remembered -------------------------------------

extension FilesModelTests {
    /// No window shows the panel: a change marks the project and lists nothing. Shown again, the
    /// marked project is listed once, the others not at all.
    func testAHiddenPanelListsNothing() async {
        let lister = Lister()
        var made: [String: FakeWatcher] = [:]
        let holder = FilesHolder { self.model([self.demo, self.acme], lister: lister) { made[$0.path] = $0 } }
        let files = holder.model
        var viewer: PanelViewer? = holder.register()
        await files.settled()
        let before = (lister.count(demo.path), lister.count(acme.path))

        viewer?.release()
        made[demo.path]!.fire(["src/app.ts"])
        made[demo.path]!.fire()
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before.0, "nothing is listed while no window shows the panel")

        // A project added while hidden waits too.
        let docs = Project(name: "docs", path: "/work/docs")
        files.update(projects: [demo, acme, docs])
        await files.settled()
        XCTAssertEqual(lister.count(docs.path), 0)

        viewer = holder.register()
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before.0 + 1, "the marked project is listed once")
        XCTAssertEqual(lister.count(acme.path), before.1, "one that did not change is not")
        XCTAssertEqual(lister.count(docs.path), 1)
        viewer = nil
        XCTAssertFalse(files.isShown)
    }

    /// A change only under an ignored folder lists nothing; a change beside it does, and a changed
    /// `.gitignore` reads the ignored folders again.
    func testIgnoredBuildOutputTriggersNothing() async {
        let lister = Lister()
        let rules = IgnoredRules(["build", "node_modules", ".DS_Store"])
        var made: [String: FakeWatcher] = [:]
        let files = ignoringModel(rules, lister: lister) { made[$0.path] = $0 }
        await files.settled()
        XCTAssertEqual(rules.reads, 1, "read with the first listing")
        let before = lister.count(demo.path)

        made[demo.path]!.fire(["build/out/app.o", "build", "node_modules/left-pad/index.js", ".DS_Store"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before, "only ignored paths changed")
        XCTAssertEqual(rules.reads, 1)

        made[demo.path]!.fire(["build/out/app.o", "src/app.ts"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before + 1)

        rules.set(["node_modules"])
        let reads = rules.reads
        made[demo.path]!.fire([".gitignore"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before + 2)
        XCTAssertEqual(rules.reads, reads + 1, "a changed rule lists the ignored paths again")
        made[demo.path]!.fire(["build/out/app.o"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before + 3, "build/ is no longer ignored")
    }

    private func ignoringModel(_ rules: IgnoredRules, lister: Lister, clock: TestClock = TestClock(),
                               watchers: @escaping (FakeWatcher) -> Void) -> FilesModel {
        FilesModel(projects: [demo], launcher: launcher, defaults: ScratchDefaults.make(),
                   watcher: { let w = FakeWatcher($0); watchers(w); return w },
                   list: { path, launcher in lister.list(path, launcher) },
                   ignored: { _, _ in rules.read() }, now: { clock.now })
    }

    /// A folder that appears after the list was read (a first build's `dist/`) is learnt: the
    /// listing a change outside the list causes reads the list again too, at most every 30 s.
    func testANewIgnoredFolderIsLearnt() async {
        let lister = Lister()
        let rules = IgnoredRules([])
        let clock = TestClock()
        var made: [String: FakeWatcher] = [:]
        let files = ignoringModel(rules, lister: lister, clock: clock) { made[$0.path] = $0 }
        await files.settled()
        let before = lister.count(demo.path)

        rules.set(["dist"])   // the first build made it
        made[demo.path]!.fire(["dist/main.js"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before + 1)
        XCTAssertEqual(rules.reads, 2, "read again with that listing")
        made[demo.path]!.fire(["dist/main.js"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before + 1, "learnt: its next changes read nothing")

        // Within 30 s, another change outside the list lists the project but not the rules.
        rules.set(["dist", "coverage"])
        made[demo.path]!.fire(["coverage/index.html"])
        await files.settled()
        XCTAssertEqual(rules.reads, 2)
        XCTAssertEqual(lister.count(demo.path), before + 2)
        // Git's own folder never asks.
        clock.advance(by: 31)
        made[demo.path]!.fire([".git/HEAD"])
        await files.settled()
        XCTAssertEqual(rules.reads, 2)
        made[demo.path]!.fire(["coverage/index.html"])
        await files.settled()
        XCTAssertEqual(rules.reads, 3, "30 s on, the rules are read again")
        made[demo.path]!.fire(["coverage/index.html"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before + 4)
    }

    /// The index changed (`git add -f dist/keep.js`): the ignored paths are listed again, so the
    /// now tracked file's changes count. A `.gitignore` a tool writes in an ignored folder is not a
    /// rule git reads, and changes nothing.
    func testTheIndexIsARuleAndAnIgnoredGitignoreIsNot() async {
        let lister = Lister()
        let rules = IgnoredRules(["dist", ".venv"])
        var made: [String: FakeWatcher] = [:]
        let files = ignoringModel(rules, lister: lister) { made[$0.path] = $0 }
        await files.settled()
        let before = lister.count(demo.path)

        made[demo.path]!.fire([".venv/.gitignore", ".venv/bin/python"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before)
        XCTAssertEqual(rules.reads, 1)

        rules.set([".venv", "dist/other.js"])
        made[demo.path]!.fire([".git/index"])
        await files.settled()
        XCTAssertEqual(rules.reads, 2)
        made[demo.path]!.fire(["dist/keep.js"])
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), before + 2, "the force-added file counts")
    }

    /// A listing promised after the running one, when the panel hides, waits for the panel.
    func testAListingPendingWhenThePanelHidesWaits() async {
        let lister = Lister()
        var made: [String: FakeWatcher] = [:]
        let files = model([demo], lister: lister) { made[$0.path] = $0 }
        await files.settled()
        let gate = lister.holdNext()
        made[demo.path]!.fire(["src/app.ts"])
        await files.eventsDelivered()
        await lister.waitUntilHeld()
        made[demo.path]!.fire(["src/app.ts"])   // one more after the running one
        await files.eventsDelivered()
        files.setShown(false)
        gate.signal()
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), 2, "the first listing and the held one, not the pending one")
        files.setShown(true)
        await files.settled()
        XCTAssertEqual(lister.count(demo.path), 3)
    }

    /// On load, what is stored for a project the workspace no longer has, and for a folder that
    /// is gone, is dropped; the rest stays, and so does a project whose own folder is missing.
    func testRemovedProjectsAreForgotten() async throws {
        let root = TestScratch.root.appendingPathComponent("shellforge-files-prune-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/demo/src/views", withIntermediateDirectories: true)
        let kept = Project(name: "demo", path: root + "/demo")
        let unplugged = Project(name: "archive", path: root + "/archive")
        let removed = UUID()
        let defaults = ScratchDefaults.make()
        defaults.set([kept.id.uuidString: ["src", "src/views", "dist", ""],
                      unplugged.id.uuidString: ["old"],
                      removed.uuidString: ["src"]], forKey: FilesModel.expandedKey)
        let files = FilesModel(projects: [], launcher: launcher, defaults: defaults, watcher: { FakeWatcher($0) },
                               list: { _, _ in .git([]) }, ignored: { _, _ in .none })
        files.follow(Just([kept, unplugged]))
        await files.pruning?.value
        let stored = defaults.dictionary(forKey: FilesModel.expandedKey) as? [String: [String]]
        XCTAssertEqual(stored, [kept.id.uuidString: ["src", "src/views", ""], unplugged.id.uuidString: ["old"]])
        XCTAssertTrue(files.isOpen(project: kept.id, folder: "src/views"))
        XCTAssertFalse(files.isOpen(project: kept.id, folder: "dist"))
    }

    /// An empty workspace — perhaps one that could not be read — forgets no project.
    func testAnEmptyWorkspaceForgetsNothing() async {
        let defaults = ScratchDefaults.make()
        let saved = [UUID().uuidString: ["src"]]
        defaults.set(saved, forKey: FilesModel.expandedKey)
        let files = FilesModel(projects: [], launcher: launcher, defaults: defaults, watcher: { FakeWatcher($0) },
                               list: { _, _ in .git([]) }, ignored: { _, _ in .none })
        files.follow(Just([]))
        await files.pruning?.value
        XCTAssertEqual(defaults.dictionary(forKey: FilesModel.expandedKey) as? [String: [String]], saved)
    }
}

/// What a test says the repository ignores, counting the reads.
private final class IgnoredRules: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: Set<String>
    private var count = 0
    init(_ entries: Set<String>) { self.entries = entries }
    func read() -> IgnoredPaths { lock.withLock { count += 1; return IgnoredPaths(entries) } }
    func set(_ entries: Set<String>) { lock.withLock { self.entries = entries } }
    var reads: Int { lock.withLock { count } }
}
