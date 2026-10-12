// Ported from AiTerm (app/Sources/AiTermCore/Models.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// A Jira project whose tickets belong to a Shellforge project.
public struct JiraProjectRef: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: String, key: String, name: String
    public var siteURL: URL
    public init(id: String, key: String, name: String, siteURL: URL) {
        self.id = id; self.key = key; self.name = name; self.siteURL = siteURL
    }

    /// The project's own page on its site. `/browse/<KEY>` is the one path that works for every
    /// project type — Jira redirects it to whatever board or backlog the project actually has —
    /// and it is the same shape `JiraClient` already gives a ticket.
    public var browseURL: URL { siteURL.appendingPathComponent("browse/\(key)") }
}

extension Array where Element == JiraProjectRef {
    /// The keys as a reader says them — "SHOP", "SHOP and PAY", "SHOP, PAY and WEB" — for the copy that
    /// names what a search covers.
    public var keyList: String {
        let keys = map(\.key)
        guard let last = keys.last else { return "" }
        return keys.count == 1 ? last : keys.dropLast().joined(separator: ", ") + " and " + last
    }

    /// The list with every repeat of a project after its first dropped: what a project links.
    public var linkedOnce: [JiraProjectRef] {
        var seen = Set<String>()
        return filter { seen.insert($0.id).inserted }
    }
}

/// Any JSON value, kept as read so a row this build does not understand can be written back as it
/// came. Integers stay integers: a number routed through `Double` would not survive a resave.
indirect enum StoredJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([StoredJSON]), object([String: StoredJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([StoredJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: StoredJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
