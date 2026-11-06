import Foundation

/// A task that runs its agent in the project's own folder, on whatever is checked out there: no
/// worktree is made, and none is ever removed.
public enum ProjectFolderTasks {
    public static func make(draft: TaskDraft, in project: Project, launcher: CommandLauncher) throws -> TaskItem {
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskWorktrees.Refusal.emptyTitle }
        guard !draft.model.isEmpty else { throw TaskWorktrees.Refusal.emptyModel }
        let branch = try checkedOutBranch(of: project, launcher: launcher)
        return TaskItem(projectId: project.id, title: draft.title, branch: branch, worktreePath: project.path,
                        baseBranch: draft.baseBranch, agent: draft.agentId, model: draft.model, reasoning: draft.reasoning,
                        jira: draft.ticket.map { JiraRef(key: $0.key, summary: $0.summary, url: $0.url) })
    }

    /// The branch checked out in the project's folder; on a detached HEAD, the short commit.
    public static func checkedOutBranch(of project: Project, launcher: CommandLauncher) throws -> String {
        func git(_ args: [String]) throws -> String {
            let out = try launcher.run("git", ["-C", project.path] + args)
            guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let branch = (try? git(["symbolic-ref", "--quiet", "--short", "HEAD"])) ?? ""
        return branch.isEmpty ? try git(["rev-parse", "--short", "HEAD"]) : branch
    }

    /// Whether the task works in the project's own folder, symlinks resolved.
    public static func isProjectFolder(_ task: TaskItem, in project: Project) -> Bool {
        ExistingWorktrees.resolved(task.worktreePath) == ExistingWorktrees.resolved(project.path)
    }
}
