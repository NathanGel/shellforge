// Ported from AiTerm (app/Sources/AiTermCore/Jira/JiraProjectSearch.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Filters and orders the account's Jira projects for the picker's field. The whole list already
/// lives in memory — `JiraClient.projects()` pages it in once — so this is a pure function over an
/// array rather than a query against Jira, and it can be tested without a network.
///
/// Three tiers, because with a few hundred projects a substring match alone buries the one whose
/// key you just typed: a key that starts with the query first, then a name that starts with it,
/// then a match anywhere in either. Within a tier, Jira's own name order is kept — the picker shows
/// six rows, and reordering equals on some second criterion would only make the list restless.
///
/// `excluding` is what the sheet has already linked: a project is linked once, so it is not offered
/// again.
public enum JiraProjectSearch {
    public static func rank(_ projects: [JiraProjectRef], query: String,
                            excluding linked: [JiraProjectRef] = []) -> [JiraProjectRef] {
        let linkedIds = Set(linked.map(\.id))
        let projects = linkedIds.isEmpty ? projects : projects.filter { !linkedIds.contains($0.id) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return projects }
        return projects.enumerated()
            .compactMap { position, project -> (tier: Int, position: Int, project: JiraProjectRef)? in
                let key = project.key.lowercased(), name = project.name.lowercased()
                if key.hasPrefix(query) { return (0, position, project) }
                if name.hasPrefix(query) { return (1, position, project) }
                if key.contains(query) || name.contains(query) { return (2, position, project) }
                return nil
            }
            .sorted { ($0.tier, $0.position) < ($1.tier, $1.position) }
            .map(\.project)
    }
}
