import Foundation
import ShellforgeCore

/// New Review: its sheet's model, and the review it creates.
extension SidebarModel {
    /// The New Review sheet for `projectId`: the agent and model New Task would open with, the
    /// project's branches, and the search of its open merge requests — on GitLab or GitHub, as its
    /// remote says, with the connection as it stands now. The remote and the connections are read
    /// off the main actor: a git call and Keychain reads.
    public func makeReviewModel(for projectId: UUID) async -> ReviewCreationModel? {
        guard let project = document.workspace.projects.first(where: { $0.id == projectId }), !agents.isEmpty else { return nil }
        let launcher = self.launcher, path = project.path
        let readGitLab = gitLabSettings, readGitHub = gitHubSettings
        let read = await BackgroundWork.run { () -> (RemoteInfo, GitLabConfig?, GitHubConfig?) in
            let url = try? launcher.run("git", ["-C", path, "remote", "get-url", "origin"])
            let remote = ProviderDetector.detect(remoteUrl: url?.status == 0 ? url?.stdout : nil, repoPath: path)
            return (remote, readGitLab(), readGitHub())
        }
        let available = Set(agents.filter { launcher.locate($0.command) != nil }.map(\.id))
        let last = document.workspace.lastAgentByProject[projectId]
        let agentId = last.flatMap { available.contains($0) ? $0 : nil } ?? agents.first { available.contains($0.id) }?.id ?? agents[0].id
        return ReviewCreationModel(project: project, agents: agents, available: available,
                                   draft: ReviewDraft(mr: nil, agentId: agentId, model: "", reasoning: nil),
                                   rememberedModels: document.workspace.lastModelByAgent, catalogue: catalogue,
                                   branches: { Repository.branches(of: path, launcher: launcher) },
                                   codeHost: MergeRequestSearch.host(for: read.0),
                                   searchMergeRequests: ReviewCreationModel.searcher(gitLab: read.1, gitHub: read.2, remote: read.0),
                                   submit: { [weak self] draft in try await self?.newReview(draft: draft, in: projectId) },
                                   home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// AiTerm's review create: the merge request's branch in a worktree of its own, the agent's
    /// command with the typed prompt, then the review saved and its tab opened running the agent.
    public func newReview(draft: ReviewDraft, in projectId: UUID) async throws {
        guard let project = document.workspace.projects.first(where: { $0.id == projectId }),
              let agent = agents.first(where: { $0.id == draft.agentId }) else { return }
        let launcher = self.launcher
        // Held for Remove Project from the start of git's work until the task is saved.
        let made = try await whileCreating(in: projectId) { () async throws -> (TaskItem, String) in
            let made = try await BackgroundWork.run { () throws -> (TaskItem, String) in
                guard launcher.locate(agent.command) != nil else { throw AgentNotInstalled(agent: agent.name) }
                let review = try ReviewWorktrees.create(draft: draft, in: project, launcher: launcher)
                let command = try AgentCommand.build(agent: agent, model: draft.model, reasoning: draft.reasoning,
                                                     prompt: draft.promptText.isEmpty ? nil : draft.promptText,
                                                     worktreePath: review.worktreePath, launcher: launcher)
                return (review, command)
            }
            try document.update { workspace in
                workspace.tasks.append(made.0)
                workspace.remember(draft, projectId: projectId)
                if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].collapsed = false }
            }
            return made
        }
        selectedTaskId = made.0.id
        selectedTerminalId = nil
        host.openTab(in: made.0.worktreePath, taskId: made.0.id, projectId: projectId, title: made.0.title, command: made.1,
                     environment: openingTaskTab(in: projectId))
    }
}
