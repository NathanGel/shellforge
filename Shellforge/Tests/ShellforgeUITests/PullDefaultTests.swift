// Ported from AiTerm (app/Sources/AiTerm/ProjectActions.swift: pullDefault), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The project menu's "Pull main": run off the main actor, one at a time per project; its outcome
/// said in the sidebar's notice, which clears itself, and a refusal as the error.
@MainActor @Suite struct PullDefaultTests {
    private func git(_ repo: GitRepoForUI, _ args: [String], in dir: String? = nil) throws {
        let out = try repo.launcher.run("git", ["-C", dir ?? repo.path] + args)
        guard out.status == 0 else { throw GitFailure(command: "git", message: out.stderr) }
    }

    /// A project whose origin is a local bare repository, with `ahead` commits pushed there by
    /// another clone.
    private func setup(originAhead: Int) async throws -> (SidebarModel, UUID, GitRepoForUI) {
        let repo = try GitRepoForUI()
        let root = (repo.path as NSString).deletingLastPathComponent
        try git(repo, ["init", "-q", "--bare", "-b", "main", root + "/remote.git"])
        try git(repo, ["remote", "add", "origin", root + "/remote.git"])
        try git(repo, ["push", "-q", "origin", "main"])
        try git(repo, ["clone", "-q", root + "/remote.git", root + "/other"], in: root)
        for i in 0..<originAhead { try git(repo, ["commit", "-q", "--allow-empty", "-m", "\(i)"], in: root + "/other") }
        try git(repo, ["push", "-q", "origin", "main"], in: root + "/other")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("pull-\(UUID().uuidString)")))
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: repo.launcher, jiraSettings: { nil })
        await model.addProject(folder: repo.path)
        return (model, try #require(document.workspace.projects.first).id, repo)
    }

    @Test func pullSaysItsOutcomeThenClearsIt() async throws {
        let (model, project, _) = try await setup(originAhead: 2)
        model.noticeLifetime = .milliseconds(50)
        await model.pullDefault(project: project)
        #expect(model.notice == "main updated with 2 new commits.")
        #expect(model.defaultBranch(of: project) == "main")
        #expect(await eventually { model.notice == nil })
    }

    @Test func aRefusalIsTheError() async throws {
        let (model, project, repo) = try await setup(originAhead: 1)
        try git(repo, ["commit", "-q", "--allow-empty", "-m", "mine"])
        await model.pullDefault(project: project)
        #expect(model.notice == nil)
        #expect(model.lastError == "Couldn’t pull main. Your local “main” has 1 commit that isn’t on origin, and origin has 1 commit it doesn’t.")
    }

    /// A second Pull while the first runs does nothing: nothing can run between the check and it.
    @Test func oneAtATimePerProject() async throws {
        let (model, project, _) = try await setup(originAhead: 1)
        let first = Task { await model.pullDefault(project: project) }
        await eventually { model.isPulling(project) }
        #expect(await model.pullDefault(project: project) == false)
        #expect(await first.value)
        #expect(!model.isPulling(project))
        #expect(model.notice == "main updated with 1 new commit.")
    }

    /// Every window over the workspace sees the pull: its menu greys, and its Pull does nothing.
    @Test func oneAtATimeAcrossWindows() async throws {
        let (model, project, repo) = try await setup(originAhead: 1)
        let other = SidebarModel(host: FakeTerminalHost(), document: model.document, launcher: repo.launcher, jiraSettings: { nil })
        let first = Task { await model.pullDefault(project: project) }
        await eventually { model.isPulling(project) }
        #expect(other.isPulling(project))
        #expect(await other.pullDefault(project: project) == false)
        #expect(await first.value)
        #expect(!other.isPulling(project))
    }

    /// A branch git could not name is not guessed: a guess would move the wrong branch.
    @Test func anUnreadableDefaultBranchPullsNothing() async throws {
        let (model, project, repo) = try await setup(originAhead: 1)
        let before = try repo.launcher.run("git", ["-C", repo.path, "rev-parse", "main"]).stdout
        try FileManager.default.moveItem(atPath: repo.path + "/.git", toPath: repo.path + "/.git-away")
        await model.pullDefault(project: project)
        try FileManager.default.moveItem(atPath: repo.path + "/.git-away", toPath: repo.path + "/.git")
        #expect(model.notice == nil)
        #expect(model.lastError?.hasPrefix("Couldn’t pull the default branch.") == true)
        #expect(try repo.launcher.run("git", ["-C", repo.path, "rev-parse", "main"]).stdout == before)
    }

    /// A notice's timer clears only its own: the same words said again stay their full time.
    @Test func aRepeatedNoticeStaysItsFullTime() async throws {
        let (model, _, _) = try await setup(originAhead: 0)
        model.noticeLifetime = .seconds(1)
        model.show(notice: "main is already up to date.")
        try await Task.sleep(for: .milliseconds(600))
        model.show(notice: "main is already up to date.")
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.notice == "main is already up to date.", "the first timer has fired, and left the second")
        #expect(await eventually { model.notice == nil })
    }

    @Test func aPullKeepsAnUnrelatedError() async throws {
        let (model, project, _) = try await setup(originAhead: 1)
        model.lastError = "Branch fix-login kept: 1 commit not on origin."
        await model.pullDefault(project: project)
        #expect(model.notice == "main updated with 1 new commit.")
        #expect(model.lastError == "Branch fix-login kept: 1 commit not on origin.")
    }

    @Test func aPullClearsItsOwnEarlierError() async throws {
        let (model, project, repo) = try await setup(originAhead: 1)
        try git(repo, ["commit", "-q", "--allow-empty", "-m", "mine"])
        await model.pullDefault(project: project)
        #expect(model.lastError?.hasPrefix("Couldn’t pull main.") == true)
        try git(repo, ["reset", "-q", "--hard", "HEAD~1"])
        await model.pullDefault(project: project)
        #expect(model.lastError == nil)
    }

    /// Two projects refused in the same words: one's good pull leaves the other's error, which is
    /// the one shown.
    @Test func aPullClearsOnlyTheErrorItOwns() async throws {
        let (model, a, repoA) = try await setup(originAhead: 1)
        try git(repoA, ["commit", "-q", "--allow-empty", "-m", "mine"])
        let (other, _, repoB) = try await setup(originAhead: 1)
        _ = other
        try git(repoB, ["commit", "-q", "--allow-empty", "-m", "mine"])
        await model.addProject(folder: repoB.path)
        let b = try #require(model.document.workspace.projects.last).id
        await model.pullDefault(project: a)
        await model.pullDefault(project: b)
        let shown = try #require(model.lastError)
        try git(repoA, ["reset", "-q", "--hard", "HEAD~1"])
        await model.pullDefault(project: a)
        #expect(model.lastError == shown, "B's refusal, in A's words, stays")
    }

    /// Only a project whose menu offers Pull has its default branch read at launch.
    @Test func onlyHostedProjectsReadTheirDefaultBranch() async throws {
        let (model, project, _) = try await setup(originAhead: 0)
        await eventually { model.providers[project] != nil }
        #expect(model.providers[project] == .git)
        #expect(model.defaultBranches[project] == nil)
        let hosted = try GitRepoForUI()
        try git(hosted, ["remote", "add", "origin", "git@github.com:example/hosted.git"])
        await model.addProject(folder: hosted.path)
        let id = try #require(model.document.workspace.projects.last).id
        #expect(await eventually { model.providers[id] == .github })
        #expect(model.defaultBranches[id] == "main")
    }

    @Test func theMenuOffersItOnlyForAHostedProject() {
        #expect(SidebarModel.pullTitle(branch: "develop") == "Pull develop")
        #expect(SidebarModel.offersPull(.gitlab) && SidebarModel.offersPull(.github))
        #expect(!SidebarModel.offersPull(.git) && !SidebarModel.offersPull(.none))
    }
}
