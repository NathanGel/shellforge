// Ported from AiTerm (app/Sources/AiTerm/Views/SidebarRows.swift), GPLv3, Laurens D'Hondt.
import AppKit
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// A project header's `ProjectJiraBadge`, drawn as `BranchLabelView` draws a branch and its `+n`: a
/// quiet `Badge` opening the first project, then — `Space.snug` after it — a boxed `+n` `Badge` whose
/// menu offers every project and ends in the context menu's "Jira Projects…".
struct ProjectJiraBadgeView: View {
    let badge: ProjectJiraBadge
    /// Whether "Jira Projects…" may open: AiTerm greys it while the workspace is locked, which
    /// Shellforge's never is, so the header passes `true`.
    let canChangeWorkspace: Bool
    let editProjects: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        HStack(spacing: scale(Space.snug)) {
            Badge(badge.label, icon: .brand(Palette.jira), help: badge.help, style: .quiet,
                  action: { ExternalLink.open(badge.url.absoluteString) })
            if let overflow = badge.overflow {
                Badge(overflow.label, help: overflow.help, accessibilityLabel: overflow.accessibilityLabel) {
                    ForEach(overflow.items, id: \.url) { item in
                        Button(item.title) { ExternalLink.open(item.url.absoluteString) }
                    }
                    Divider()
                    Button("Jira Projects…", action: editProjects).disabled(!canChangeWorkspace)
                }
            }
        }
    }
}

/// The Jira badge a project row wears beside its own name: the first linked Jira project's key,
/// which opens it, and — when the project links more — a `+n` after it, the way a branch label
/// counts a window's other branches, whose menu offers every one of them. A presentational value
/// rather than an expression inside the row, so the rule — what the badge says, and where it points —
/// is testable without rendering the sidebar.
struct ProjectJiraBadge: Equatable {
    /// The `+n` after the first project's key, for a project that links more than one.
    struct Overflow: Equatable {
        let label: String
        let help: String
        let accessibilityLabel: String
        /// Every linked project, the first included, in the order they were linked.
        let items: [MenuItem]
    }

    struct MenuItem: Equatable {
        let title: String
        let url: URL
    }

    /// The first project's key, unless the key is switched off and the mark stands alone. AiTerm's
    /// Interface tab holds that switch; Shellforge has none yet, so its rows always show the key.
    let label: String?
    let help: String
    let url: URL
    /// The rest, when there is more than one; not a key, so the key switch leaves it.
    let overflow: Overflow?

    /// The project's badge, or none when it links no Jira project.
    static func badge(for project: Project, showsKey: Bool = true) -> ProjectJiraBadge? {
        guard let first = project.jiraProjects.first else { return nil }
        return ProjectJiraBadge(jira: first, showsKey: showsKey, overflow: Overflow(project.jiraProjects))
    }

    init(jira: JiraProjectRef, showsKey: Bool = true) {
        self.init(jira: jira, showsKey: showsKey, overflow: nil)
    }

    private init(jira: JiraProjectRef, showsKey: Bool, overflow: Overflow?) {
        label = showsKey ? jira.key : nil
        url = jira.browseURL
        // The row shows the key only; the project's full name is worth a hover, and the URL beside
        // it is what every other badge in the sidebar puts there. A badge without its key names it
        // there too.
        help = "\(showsKey ? jira.name : "\(jira.name) (\(jira.key))") — \(jira.browseURL.absoluteString)"
        self.overflow = overflow
    }
}

extension ProjectJiraBadge.Overflow {
    /// The `+n` for `jira`, or none when there is nothing past the first.
    init?(_ jira: [JiraProjectRef]) {
        let rest = Array(jira.dropFirst())
        guard !rest.isEmpty else { return nil }
        label = "+\(rest.count)"
        items = jira.map { .init(title: "\($0.key) — \($0.name)", url: $0.browseURL) }
        // A count says nothing on its own: the hover names every project, and VoiceOver the rest.
        help = (["Jira"] + jira.map { "\($0.key) \($0.name)" }).joined(separator: " · ")
        accessibilityLabel = "\(rest.count) more Jira \(rest.count == 1 ? "project" : "projects"): \(rest.keyList)"
    }
}

/// A task row's ticket badge: AiTerm's `TaskRowBadges.ticket`. A badge whose key is switched off
/// keeps its mark and its link; the key it no longer prints leads its tooltip instead.
struct TaskTicketBadge: Equatable {
    var label: String?
    var help: String
    var url: String?

    init(label: String?, help: String, url: String?) {
        self.label = label; self.help = help; self.url = url
    }

    /// None for a task made without a ticket. A ticket saved without its link still names its key.
    init?(jira: JiraRef?, showsKey: Bool = true) {
        guard let jira else { return nil }
        let url = jira.url.isEmpty ? nil : jira.url
        if showsKey {
            self.init(label: jira.key, help: url ?? jira.key, url: url)
        } else {
            self.init(label: nil, help: url.map { "\(jira.key) — \($0)" } ?? jira.key, url: url)
        }
    }
}
