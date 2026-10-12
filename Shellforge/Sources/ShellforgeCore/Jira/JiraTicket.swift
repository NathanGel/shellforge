// Ported from AiTerm (app/Sources/AiTermCore/Jira/JiraTicket.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// A Jira issue as the New Task sheet shows and prompts with it.
public struct JiraTicket: Equatable, Sendable {
    public var key: String, summary: String, description: String?, issueType: String?, status: String?, url: String
    public init(key: String, summary: String, description: String?, issueType: String?, status: String?, url: String) {
        self.key = key; self.summary = summary; self.description = description; self.issueType = issueType; self.status = status; self.url = url
    }
}

/// `SearchPicker` is generic over `Item: Identifiable`; a ticket's `key` is already unique and
/// `ForEach` keyed on it before this conformance existed.
extension JiraTicket: Identifiable { public var id: String { key } }
