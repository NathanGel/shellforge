import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The sidebar's keyboard commands and their rules: which project New Task acts on, stepping
/// through tasks, Focus View and List View, and the sheets they ask for. Workspaces are written
/// directly: tasks need no worktree to be listed.
@MainActor @Suite struct SidebarCommandsTests {

    private func task(_ title: String, in project: UUID) -> TaskItem {
        TaskItem(projectId: project, title: title, branch: "feat/\(title)", worktreePath: "/wt/\(title)", baseBranch: "main")
    }

    /// Projects `a` (tasks a1, a2) and `b` (task b1), and the model over them.
    private func model(projects names: [String] = ["a", "b"], feed: FakeFeed = FakeFeed())
        throws -> (SidebarModel, FakeTerminalHost, WorkspaceDocument, [String: UUID]) {
        // A folder of its own each: two models in one test must not share a workspace.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-commands-\(UUID().uuidString)")
        let document = WorkspaceDocument(store: WorkspaceStore(folder: folder))
        var ids: [String: UUID] = [:]
        try document.update { workspace in
            for name in names {
                let project = Project(name: name, path: "/\(name)")
                ids[name] = project.id
                workspace.projects.append(project)
            }
            if let a = ids["a"] { workspace.tasks += [task("a1", in: a), task("a2", in: a)] }
            if let b = ids["b"] { workspace.tasks.append(task("b1", in: b)) }
        }
        for task in document.workspace.tasks { ids[task.title] = task.id }
        let host = FakeTerminalHost()
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: host, document: document, launcher: launcher, feed: feed, jiraSettings: { nil })
        return (model, host, document, ids)
    }

    @Test func theTargetProjectRule() throws {
        let (model, _, _, ids) = try model()
        #expect(model.targetProject == nil, "several projects, none selected")
        #expect(!model.can(.newTask) && !model.can(.newReview))
        model.select(task: try #require(ids["b1"]))
        #expect(model.targetProject == ids["b"])
        #expect(model.can(.newTask) && model.can(.newReview))
        let (single, _, _, singleIds) = try self.model(projects: ["a"])
        #expect(single.targetProject == singleIds["a"], "the only project, with nothing selected")
        let (empty, _, _, _) = try self.model(projects: [])
        #expect(empty.targetProject == nil && empty.can(.addProject))
    }

    @Test func nextAndPreviousWrap() throws {
        let (model, _, _, ids) = try model()
        model.perform(.nextTask)
        #expect(model.selectedTaskId == ids["a1"], "with none selected, the first")
        model.perform(.nextTask)
        model.perform(.nextTask)
        #expect(model.selectedTaskId == ids["b1"])
        model.perform(.nextTask)
        #expect(model.selectedTaskId == ids["a1"], "past the last, the first")
        model.perform(.previousTask)
        #expect(model.selectedTaskId == ids["b1"], "before the first, the last")
        let (empty, _, _, _) = try self.model(projects: [])
        #expect(!empty.can(.nextTask))
        empty.perform(.nextTask)
        #expect(empty.selectedTaskId == nil)
    }

    @Test func focusViewOpensWhatWaitsAndShowsTheFirst() throws {
        let feed = FakeFeed()
        let (model, _, document, ids) = try model(feed: feed)
        model.toggleCollapsed(try #require(ids["b"]))
        feed.sayAll([(.needsInput, "s1", try #require(ids["b1"]), .claude), (.working, "s2", try #require(ids["a1"]), .claude)])
        #expect(model.waitingOnYou == [ids["b1"]])
        model.perform(.focusView)
        #expect(document.workspace.projects.first { $0.id == ids["b"] }?.collapsed == false, "the project with a task waiting opens")
        #expect(document.workspace.projects.first { $0.id == ids["a"] }?.collapsed == true, "the rest fold")
        #expect(model.selectedTaskId == ids["b1"])
    }

    @Test func listViewOpensEveryProject() throws {
        let (model, _, document, ids) = try model()
        model.toggleCollapsed(try #require(ids["a"]))
        model.toggleCollapsed(try #require(ids["b"]))
        model.perform(.listView)
        #expect(document.workspace.projects.allSatisfy { !$0.collapsed })
    }

    @Test func sheetCommandsAreRequested() throws {
        let (model, _, _, ids) = try model()
        var requests: [SidebarSheetRequest] = []
        let subscription = model.sheetRequests.sink { requests.append($0) }
        model.select(task: try #require(ids["a2"]))
        model.perform(.newTask)
        model.perform(.newReview)
        model.perform(.addProject)
        model.perform(.removeTask)
        let a = try #require(ids["a"]), a2 = try #require(ids["a2"])
        let expected: [SidebarSheetRequest] = [.newTask(a), .newReview(a), .addProject, .removeTask(a2)]
        #expect(requests == expected)
        _ = subscription
    }

    @Test func removeNeedsASelectedTask() throws {
        let (model, _, _, _) = try model()
        #expect(!model.can(.removeTask))
    }
}
