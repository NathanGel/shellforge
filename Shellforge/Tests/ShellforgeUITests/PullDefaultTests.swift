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
        model.lastError = "an older failure"
        await model.pullDefault(project: project)
        #expect(model.notice == "main updated with 2 new commits.")
        #expect(model.lastError == nil)
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

    @Test func theMenuOffersItOnlyForAHostedProject() {
        #expect(SidebarModel.pullTitle(branch: "develop") == "Pull develop")
        #expect(SidebarModel.offersPull(.gitlab) && SidebarModel.offersPull(.github))
        #expect(!SidebarModel.offersPull(.git) && !SidebarModel.offersPull(.none))
    }
}
