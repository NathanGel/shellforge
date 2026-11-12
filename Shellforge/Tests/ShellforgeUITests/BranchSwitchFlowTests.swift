import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
import ShellforgeTestSupport

private final class QuietWatcher: FolderWatching, @unchecked Sendable {
    func watch(_ path: String, onChange: @escaping @Sendable () -> Void) {}
    func stop() {}
}

/// Stands in for the Trash: moves each file into a folder of its own and records it.
private final class FakeTrash: @unchecked Sendable {
    let folder = TestScratch.root.appendingPathComponent("shellforge-trash-\(UUID().uuidString)")
    private let lock = NSLock()
    private var moved: [URL] = []

    func trash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        lock.withLock { moved.append(target) }
    }

    var items: [URL] { lock.withLock { moved } }
}

/// Answers from a script, and runs `onAnswer` with each answer before giving it.
@MainActor private final class ReactingPrompter: Prompter {
    private(set) var asked: [AlertPrompt] = []
    var answers: [AlertAnswer]
    var onAnswer: (Int) -> Void = { _ in }
    init(_ answers: [AlertAnswer]) { self.answers = answers }
    func ask(_ prompt: AlertPrompt) async -> AlertAnswer {
        asked.append(prompt)
        onAnswer(asked.count)
        return answers.isEmpty ? AlertAnswer(button: prompt.escapeButton ?? 0) : answers.removeFirst()
    }
}

/// Switch Branch from the Git panel asks what a Project folder task asks, and Discard asks first.
@MainActor @Suite(.serialized) struct BranchSwitchFlowTests {
    private struct Setup {
        let repo: GitRepoForUI
        let project: Project
        let model: GitModel
        let trash: FakeTrash
    }

    private func setup() async throws -> Setup {
        let repo = try GitRepoForUI()
        let project = Project(name: "demo", path: repo.path)
        let trash = FakeTrash()
        let model = GitModel(projects: [project], tasks: [], launcher: repo.launcher,
                             watcher: { _ in QuietWatcher() }, trash: { try trash.trash($0) })
        await model.settled()
        return Setup(repo: repo, project: project, model: model, trash: trash)
    }

    @discardableResult
    private func git(_ repo: GitRepoForUI, _ args: String...) throws -> String {
        let out = try repo.launcher.run("git", ["-C", repo.path] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, to name: String, in repo: GitRepoForUI) throws {
        let url = URL(fileURLWithPath: repo.path).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func status(_ model: GitModel) -> GitStatus? {
        guard case .status(let status) = model.sections.first?.state else { return nil }
        return status
    }

    @Test func theGitPanelReportsABranchInAnotherWorktree() async throws {
        let s = try await setup()
        let other = s.repo.path + "-other"
        try git(s.repo, "worktree", "add", "-q", "-b", "feature/login-page", other)
        let prompter = ScriptedPrompter([])
        let flow = BranchSwitchFlow(prompter: prompter, launcher: s.repo.launcher)
        await #expect(throws: CreationDeclined.self) {
            try await flow.switchProject(s.project, to: "feature/login-page", busyTask: { nil },
                                         stashLabel: "switching to “feature/login-page”", offerOtherWorktree: false)
        }
        #expect(prompter.asked.count == 1)
        #expect(prompter.asked.first?.message == "“feature/login-page” is checked out in another worktree.")
        let prefix = "Git keeps a branch to one worktree at a time: "
        let detail = try #require(prompter.asked.first?.detail)
        #expect(detail.hasPrefix(prefix))
        #expect(ExistingWorktrees.resolved(String(detail.dropFirst(prefix.count))) == ExistingWorktrees.resolved(other))
        #expect(prompter.asked.first?.buttons == ["OK"])
        #expect(try git(s.repo, "symbolic-ref", "--short", "HEAD") == "main")
    }

    @Test func clashingChangesOfferStashAndSwitch() async throws {
        let s = try await setup()
        try git(s.repo, "switch", "-q", "-c", "feature/login-page")
        try write("theirs\n", to: "src/app.ts", in: s.repo)
        try git(s.repo, "add", "src/app.ts")
        try git(s.repo, "commit", "-q", "-m", "theirs")
        try git(s.repo, "switch", "-q", "main")
        try write("mine\n", to: "src/app.ts", in: s.repo)
        let prompter = ScriptedPrompter([AlertAnswer(button: 0)])
        let flow = BranchSwitchFlow(prompter: prompter, launcher: s.repo.launcher)
        await s.model.switchBranch(.project(s.project.id), to: "feature/login-page", flow: flow, busyTask: { nil })
        #expect(prompter.asked.map(\.buttons) == [["Stash and Switch", "Cancel"]])
        #expect(prompter.asked.first?.message == "Uncommitted changes in demo clash with “feature/login-page”.")
        #expect(try git(s.repo, "symbolic-ref", "--short", "HEAD") == "feature/login-page")
        #expect(try git(s.repo, "stash", "list").contains("Shellforge: before switching to “feature/login-page”"))
        let section = try #require(s.model.sections.first)
        #expect(!section.busy && section.problem == nil)
        #expect(status(s.model)?.head == .branch("feature/login-page"))
    }

    @Test func anotherTaskWorkingThereAsksFirst() async throws {
        let s = try await setup()
        try git(s.repo, "branch", "feature/login-page")
        let prompter = ScriptedPrompter([AlertAnswer(button: 1)])
        let flow = BranchSwitchFlow(prompter: prompter, launcher: s.repo.launcher)
        await s.model.switchBranch(.project(s.project.id), to: "feature/login-page", flow: flow, busyTask: { "Login page" })
        #expect(prompter.asked.first?.message == "“Login page” is also working in this folder.")
        #expect(prompter.asked.first?.buttons == ["Switch Anyway", "Cancel"])
        #expect(try git(s.repo, "symbolic-ref", "--short", "HEAD") == "main")
        let section = try #require(s.model.sections.first)
        #expect(!section.busy && section.problem == nil, "a Cancel is no problem")
    }

    @Test func cancelledDiscardChangesNothing() async throws {
        let s = try await setup()
        try write("first\n", to: "src/app.ts", in: s.repo)
        try git(s.repo, "add", "src/app.ts")
        try git(s.repo, "commit", "-q", "-m", "app")
        try write("second\n", to: "src/app.ts", in: s.repo)
        await s.model.refresh(.project(s.project.id))
        let change = try #require(status(s.model)?.unstaged.first)
        let prompter = ScriptedPrompter([])   // ⎋
        #expect(await !s.model.confirmDiscard(change, prompter: prompter))
        let asked = try #require(prompter.asked.first)
        #expect(asked.message == "Discard changes to “app.ts”?")
        #expect(asked.detail == "This can’t be undone.")
        #expect(asked.buttons == ["Discard Changes", "Cancel"] && asked.defaultDeletes)
        #expect(try String(contentsOfFile: s.repo.path + "/src/app.ts", encoding: .utf8) == "second\n")
    }

    @Test func discardingAnUntrackedFileTrashesIt() async throws {
        let s = try await setup()
        try write("x\n", to: "src/app.ts", in: s.repo)
        await s.model.refresh(.project(s.project.id))
        let change = try #require(status(s.model)?.unstaged.first)
        #expect(change.letter == .untracked)
        let prompter = ScriptedPrompter([AlertAnswer(button: 0)])
        #expect(await s.model.confirmDiscard(change, prompter: prompter))
        let asked = try #require(prompter.asked.first)
        #expect(asked.message == "Move “app.ts” to the Trash?")
        #expect(asked.detail == "It isn’t in git yet, so discarding it moves the file to the Trash.")
        #expect(asked.buttons == ["Move to Trash", "Cancel"] && asked.defaultDeletes)
        await s.model.perform(.discard(change), in: .project(s.project.id))
        #expect(!FileManager.default.fileExists(atPath: s.repo.path + "/src/app.ts"))
        #expect(s.trash.items.map(\.lastPathComponent) == ["app.ts"])
        #expect(s.trash.items.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(s.model.sections.first?.problem == nil)
    }

    @Test func aTaskThatStartsWhileAnEarlierQuestionIsUpIsAskedAbout() async throws {
        let s = try await setup()
        var busy: String?
        let prompter = ReactingPrompter([AlertAnswer(button: 0), AlertAnswer(button: 1)])
        // A tab of “Login page” opens in the folder while “doesn’t exist yet” is up.
        prompter.onAnswer = { if $0 == 1 { busy = "Login page" } }
        let flow = BranchSwitchFlow(prompter: prompter, launcher: s.repo.launcher)
        await s.model.switchBranch(.project(s.project.id), to: "feature/login-page", flow: flow, busyTask: { busy })
        #expect(prompter.asked.map(\.message) == ["“feature/login-page” doesn’t exist yet.",
                                                   "“Login page” is also working in this folder."])
        #expect(try git(s.repo, "symbolic-ref", "--short", "HEAD") == "main")
        #expect(s.model.sections.first?.problem == nil)
    }

    @Test func aTaskWorktreeIsNotSwitched() async throws {
        let repo = try GitRepoForUI()
        let project = Project(name: "demo", path: repo.path)
        let path = repo.path + "/.worktrees/feature-login-page"
        try git(repo, "worktree", "add", "-q", "-b", "feature/login-page", path)
        try git(repo, "branch", "feature/other")
        let task = TaskItem(projectId: project.id, title: "Login page", branch: "feature/login-page", worktreePath: path, baseBranch: "main")
        let model = GitModel(projects: [project], tasks: [task], launcher: repo.launcher, watcher: { _ in QuietWatcher() })
        await model.settled()
        let prompter = ScriptedPrompter([])
        var asked = false
        let flow = BranchSwitchFlow(prompter: prompter, launcher: repo.launcher)
        await model.switchBranch(.task(task.id), to: "feature/other", flow: flow, busyTask: { asked = true; return nil })
        #expect(prompter.asked.isEmpty && !asked)
        let head = try repo.launcher.run("git", ["-C", path, "symbolic-ref", "--short", "HEAD"]).stdout
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "feature/login-page")
    }

    @Test func anIntentToAddFileIsMovedToTheTrashToo() async throws {
        let s = try await setup()
        try write("x\n", to: "src/app.ts", in: s.repo)
        try git(s.repo, "add", "-N", "src/app.ts")
        await s.model.refresh(.project(s.project.id))
        let change = try #require(status(s.model)?.unstaged.first)
        #expect(change.letter == .added)
        let prompter = ScriptedPrompter([])
        #expect(await !s.model.confirmDiscard(change, prompter: prompter))
        let asked = try #require(prompter.asked.first)
        #expect(asked.message == "Move “app.ts” to the Trash?")
        #expect(asked.detail == "It was only marked to be added, so discarding it moves the file to the Trash.")
        #expect(asked.buttons == ["Move to Trash", "Cancel"] && asked.defaultDeletes)
    }

    @Test func aChangeThatTurnedIntoAnotherKindIsNotDiscarded() async throws {
        let s = try await setup()
        try write("first\n", to: "src/app.ts", in: s.repo)
        try git(s.repo, "add", "src/app.ts")
        try git(s.repo, "commit", "-q", "-m", "app")
        try write("second\n", to: "src/app.ts", in: s.repo)
        await s.model.refresh(.project(s.project.id))
        let change = try #require(status(s.model)?.unstaged.first)
        #expect(await s.model.confirmDiscard(change, prompter: ScriptedPrompter([AlertAnswer(button: 0)])))
        // Before the discard runs, the file leaves the index: it would now go to the Trash.
        try git(s.repo, "rm", "-q", "--cached", "src/app.ts")
        await s.model.perform(.discard(change), in: .project(s.project.id))
        #expect(try String(contentsOfFile: s.repo.path + "/src/app.ts", encoding: .utf8) == "second\n")
        #expect(s.trash.items.isEmpty)
        #expect(status(s.model)?.unstaged.map(\.letter) == [.untracked], "the panel shows it as it is now")
        #expect(s.model.sections.first?.problem == nil)
    }
}
