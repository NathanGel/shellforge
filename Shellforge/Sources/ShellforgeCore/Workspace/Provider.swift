// Ported from AiTerm (app/Sources/AiTermCore/Models.swift: Provider), GPLv3, Laurens D'Hondt.

/// Where a project's code lives, which draws its mark in the sidebar: GitLab's tanuki, GitHub's mark,
/// plain git, or none.
public enum Provider: String, Codable, Equatable, Sendable {
    case gitlab, github, git, none
    public init(from decoder: Decoder) throws {
        self = Provider(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .git
    }
}
