// Ported from AiTerm (app/Sources/AiTermCore/Models.swift: TerminalItem), GPLv3, Laurens D'Hondt.
import Foundation

/// A terminal row: a named plain shell in its project's folder, with no worktree and no agent.
/// Kept until removed; selecting it shows its tab, or opens one when none is open.
public struct TerminalItem: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), projectId: UUID, name: String, createdAt: Date = Date()) {
        self.id = id; self.projectId = projectId; self.name = name; self.createdAt = createdAt
    }

    /// AiTerm's: "Terminal", then the lowest free "Terminal n" from 2, among `taken` names.
    public static func suggestedName(taken: [String]) -> String {
        let names = Set(taken)
        guard names.contains("Terminal") else { return "Terminal" }
        var n = 2
        while names.contains("Terminal \(n)") { n += 1 }
        return "Terminal \(n)"
    }
}
