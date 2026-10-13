import Foundation
import ShellforgeCore

/// A project's linked Jira projects.
extension SidebarModel {
    /// The project as the workspace holds it now.
    public func project(_ id: UUID) -> Project? { document.workspace.projects.first { $0.id == id } }

    /// Every Jira project the account can see, for a project's Jira Projects sheet. The connection
    /// is read off the main actor: the Keychain is slow.
    public func loadJiraProjects() async throws -> [JiraProjectRef] {
        let read = jiraSettings
        guard let config = await BackgroundWork.run(read) else {
            throw ActionUnavailable("Connect Jira in Settings to choose a Jira project.")
        }
        return try await JiraClient(config: config).projects()
    }

    /// Replaces the project's linked Jira projects with `jiraProjects`, each once, in their order.
    /// An empty list unlinks them all: New Task then searches every Jira project.
    public func setJiraProjects(_ jiraProjects: [JiraProjectRef], on projectId: UUID) {
        let linked = jiraProjects.linkedOnce
        guard let current = document.workspace.projects.first(where: { $0.id == projectId }),
              current.jiraProjects != linked else { return }
        attempt {
            try document.update { workspace in
                if let i = workspace.projects.firstIndex(where: { $0.id == projectId }) { workspace.projects[i].jiraProjects = linked }
            }
        }
    }
}
