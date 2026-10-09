// Ported from AiTerm (app/Sources/AiTermCore/Git/BranchType.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// A new task branch's prefix: the three Conventional Commits types a Jira ticket tells apart — a
/// Task or Story is `feat`, a Bug is `fix`, and the rest is `chore` — so a branch and the commits on
/// it share one vocabulary. The raw value is the prefix itself.
public enum BranchType: String, CaseIterable, Equatable, Sendable {
    case feat, fix, chore

    /// What the type means, for the select's tooltip.
    public var summary: String {
        switch self {
        case .feat: return "A new feature"
        case .fix: return "A bug fix"
        case .chore: return "Maintenance that changes no behaviour"
        }
    }

    /// The type a Jira issue type usually is. Matched on words rather than exact names, because
    /// every Jira site renames and adds its own; whatever is not recognised — a Task, a Story, a
    /// Spike — is feature work.
    public init(issueType: String?) {
        let name = (issueType ?? "").lowercased()
        func has(_ words: String...) -> Bool { words.contains { name.contains($0) } }
        if has("bug", "defect", "incident") { self = .fix }
        else if has("chore", "maintenance", "debt", "refactor", "doc") { self = .chore }
        else { self = .feat }
    }

    /// `branch` split at its first `/`, when what comes before it is a type. Case-sensitive, as git
    /// branch names are.
    public static func split(_ branch: String) -> (type: BranchType, name: String)? {
        guard let slash = branch.firstIndex(of: "/"), let type = BranchType(rawValue: String(branch[..<slash])) else { return nil }
        return (type, String(branch[branch.index(after: slash)...]))
    }
}
