// Ported from AiTerm (app/Sources/AiTermCore/Sidebar/SidebarModel.swift: BaseDiff), GPLv3, Laurens D'Hondt.
import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// A task row's VS Code badge carries `+n −m`: its worktree's lines against its base, read off
/// the main actor and published only when they change.
@MainActor @Suite struct DiffBadgeTests {
    private func model() async throws -> (SidebarModel, TaskItem) {
        let repo = try GitRepoForUI()
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("diff-\(UUID().uuidString)")))
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: repo.launcher, jiraSettings: { nil })
        model.diffStats = DiffStats(git: LauncherGit(launcher: repo.launcher), ttl: 0)
        await model.addProject(folder: repo.path)
        let project = try #require(document.workspace.projects.first)
        let task = try TaskWorktrees.create(title: "Fix login", in: project, base: "main", launcher: repo.launcher)
        try document.update { $0.tasks.append(task) }
        return (model, task)
    }

    @Test func diffsAreReadForEachTask() async throws {
        let (model, task) = try await model()
        try "a\nb\n".write(toFile: task.worktreePath + "/new.txt", atomically: true, encoding: .utf8)
        await model.refreshDiffs()
        #expect(model.diffs[task.id] == DiffStat(added: 2, removed: 0))
    }

    @Test func anUnchangedDiffRedrawsNothing() async throws {
        let (model, task) = try await model()
        await model.refreshDiffs()
        #expect(model.diffs[task.id] == DiffStat(added: 0, removed: 0))
        // The project's provider is looked up in the background too; its redraw is not this one.
        await eventually { model.providers[task.projectId] != nil }
        var count = 0
        let subscription = model.objectWillChange.sink { count += 1 }
        await model.refreshDiffs()
        #expect(count == 0)
        _ = subscription
    }

    /// Nothing changed, no base or no answer: the plain badge and its plain help.
    @Test func theBadgeHelpNamesTheBase() {
        #expect(VSCodeBadge.help(diff: DiffStat(added: 12, removed: 3), base: "main") == "Open in VS Code \u{2014} 12 added, 3 removed against main")
        #expect(VSCodeBadge.help(diff: DiffStat(added: 0, removed: 4), base: "develop") == "Open in VS Code \u{2014} 4 removed against develop")
        #expect(VSCodeBadge.help(diff: DiffStat(added: 0, removed: 0), base: "main") == "Open in VS Code")
        #expect(VSCodeBadge.help(diff: nil, base: "main") == "Open in VS Code")
        #expect(VSCodeBadge.help(diff: DiffStat(added: 1, removed: 0), base: "") == "Open in VS Code")
    }
}
