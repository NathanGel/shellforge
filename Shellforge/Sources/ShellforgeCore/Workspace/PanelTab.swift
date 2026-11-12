import Foundation

/// A tab a sidebar panel opened: an ssh session, a file in the editor, or a diff. Its tag value
/// is what the tab’s session carries in `ShellforgeTags.panel`, so the tab can be found again,
/// and filed under its row, after a relaunch.
public enum PanelTab: Hashable, Sendable {
    case ssh(alias: String)
    case file(project: UUID, path: String)
    /// `repo` is a repository’s id string: `project:<uuid>` or `task:<uuid>`.
    case diff(repo: String, path: String)

    /// `ssh:<alias>`, `files:<uuid lowercased>:<path>` or `git:<repo id>:<path>`.
    public var tagValue: String {
        switch self {
        case .ssh(let alias): return "ssh:\(alias)"
        case .file(let project, let path): return "files:\(project.uuidString.lowercased()):\(path)"
        case .diff(let repo, let path): return "git:\(repo):\(path)"
        }
    }

    public init?(tagValue: String) {
        guard let colon = tagValue.firstIndex(of: ":") else { return nil }
        let kind = tagValue[..<colon]
        let rest = String(tagValue[tagValue.index(after: colon)...])
        switch kind {
        case "ssh":
            guard !rest.isEmpty else { return nil }
            self = .ssh(alias: rest)
        case "files":
            // The uuid has no colon, so the path is everything after the first one.
            guard let split = rest.firstIndex(of: ":"),
                  let project = UUID(uuidString: String(rest[..<split])) else { return nil }
            let path = String(rest[rest.index(after: split)...])
            guard !path.isEmpty else { return nil }
            self = .file(project: project, path: path)
        case "git":
            // The repo id is itself `<kind>:<uuid>`, so the path starts after the second colon.
            let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "project" || parts[0] == "task",
                  UUID(uuidString: String(parts[1])) != nil, !parts[2].isEmpty else { return nil }
            self = .diff(repo: "\(parts[0]):\(parts[1])", path: String(parts[2]))
        default:
            return nil
        }
    }
}
