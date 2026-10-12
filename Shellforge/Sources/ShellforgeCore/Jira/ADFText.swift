// Ported from AiTerm (app/Sources/AiTermCore/Jira/ADFText.swift), GPLv3, Laurens D'Hondt.
import Foundation

public enum ADFText {
    public static func plain(_ adf: Any?) -> String {
        guard let adf else { return "" }
        if let s = adf as? String { return s }
        guard let node = adf as? [String: Any] else { return "" }
        return blocks(node).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func blocks(_ node: [String: Any]) -> [String] {
        let children = node["content"] as? [[String: Any]] ?? []
        switch node["type"] as? String {
        case "doc": return children.flatMap(blocks)
        case "paragraph", "heading": return [inline(children)]
        case "codeBlock": return ["```\n" + inline(children) + "\n```"]
        case "bulletList": return [children.map { "- " + itemText($0) }.joined(separator: "\n")]
        case "orderedList": return [children.enumerated().map { "\($0.offset + 1). " + itemText($0.element) }.joined(separator: "\n")]
        case "rule": return ["---"]
        default: return children.flatMap(blocks)
        }
    }

    private static func itemText(_ item: [String: Any]) -> String { blocks(item).joined(separator: " ") }

    private static func inline(_ nodes: [[String: Any]]) -> String {
        nodes.map { n -> String in
            switch n["type"] as? String {
            case "text": return n["text"] as? String ?? ""
            case "hardBreak": return "\n"
            case "mention": return (n["attrs"] as? [String: Any])?["text"] as? String ?? ""
            case "inlineCard": return (n["attrs"] as? [String: Any])?["url"] as? String ?? ""
            default: return inline(n["content"] as? [[String: Any]] ?? [])
            }
        }.joined()
    }
}

extension StoredJSON {
    /// The value as `JSONSerialization` would have read it, which is what `ADFText` walks.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationValue)
        case .object(let fields): return fields.mapValues(\.foundationValue)
        }
    }
}
