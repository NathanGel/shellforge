// Ported from AiTerm (app/Sources/AiTermCore/Hooks/TOMLStatements.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// A lossless view of TOML text as top-level statements, split only at newlines outside strings,
/// arrays and inline tables. Comments stay in `text`, out of `code`. Used to edit one table of a
/// user's file while every other byte, comment and table is kept exactly.
enum TOMLStatements {
    struct Statement {
        var text: String
        var code: String
        var header: (path: [String], array: Bool)? {
            let array = code.hasPrefix("[[")
            let bracket = array ? 2 : 1
            guard code.hasPrefix("["), code.hasSuffix(array ? "]]" : "]") else { return nil }
            return (Self.path(String(code.dropFirst(bracket).dropLast(bracket))), array)
        }
        /// The key an assignment names, split at its dots: `a."b.c" = 1` names `["a", "b.c"]`.
        /// `nil` for headers, comments and blank lines.
        var keyPath: [String]? {
            guard header == nil, let equals = Self.equals(in: code) else { return nil }
            return Self.path(String(code[..<equals]))
        }
        /// The string an assignment holds, in any of TOML's four string forms; `nil` for any
        /// other value, and for a string TOML itself would reject.
        var value: String? {
            guard header == nil, let equals = Self.equals(in: code) else { return nil }
            return Self.string(String(code[code.index(after: equals)...]))
        }
        /// The name an assignment gives, whatever its value: `padding = 2` names `padding` even
        /// though `assignment` only reads string values. `nil` for dotted keys, headers, comments
        /// and blank lines.
        var key: String? { keyPath.flatMap { $0.count == 1 ? $0[0] : nil } }
        var assignment: (String, String)? {
            guard let key, let value else { return nil }
            return (key, value)
        }

        /// The `=` that ends a key: the first outside a quoted key such as `"a=b"`.
        private static func equals(in code: String) -> String.Index? {
            var quote: Character?, escaped = false
            for index in code.indices {
                let c = code[index]
                if let q = quote {
                    if escaped { escaped = false }
                    else if q == "\"" && c == "\\" { escaped = true }
                    else if c == q { quote = nil }
                } else if c == "\"" || c == "'" { quote = c }
                else if c == "=" { return index }
            }
            return nil
        }

        /// A TOML string's value: basic (`"…"`, with escapes), literal (`'…'`, none), and the
        /// multi-line `"""…"""` and `'''…'''`, whose newline right after the opening quotes
        /// is not part of the value and which may end in up to two quotes of their own. `nil`
        /// for anything else, or anything left over after the closing quote.
        static func string(_ raw: String) -> String? {
            let chars = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let quote = chars.first, quote == "\"" || quote == "'" else { return nil }
            let multiline = chars.count >= 3 && chars[1] == quote && chars[2] == quote
            let basic = quote == "\""
            var i = multiline ? 3 : 1, out = ""
            if multiline, i < chars.count, chars[i].isNewline { i += 1 }
            while i < chars.count {
                let c = chars[i]
                if c == quote {
                    guard multiline else { return i == chars.count - 1 ? out : nil }
                    var run = 0
                    while i + run < chars.count, chars[i + run] == quote { run += 1 }
                    if run >= 3 {
                        guard run <= 5, i + run == chars.count else { return nil }
                        return out + String(repeating: String(quote), count: run - 3)
                    }
                    out += String(repeating: String(quote), count: run); i += run
                } else if basic, c == "\\" {
                    if multiline, let next = lineEndingBackslash(chars, at: i) { i = next; continue }
                    guard let (escaped, next) = escape(chars, at: i) else { return nil }
                    out.unicodeScalars.append(escaped); i = next
                } else {
                    guard multiline || !c.isNewline else { return nil }
                    out.append(c); i += 1
                }
            }
            return nil
        }

        /// A backslash that ends a line of a multi-line basic string swallows the newline and
        /// every space, tab and newline after it: the index of the next character kept.
        private static func lineEndingBackslash(_ chars: [Character], at i: Int) -> Int? {
            var j = i + 1
            while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
            guard j < chars.count, chars[j].isNewline else { return nil }
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            return j
        }

        /// The escape at `chars[i]`, a backslash: what it stands for and the index after it.
        /// `\e` and `\xHH` are TOML 1.1's.
        private static func escape(_ chars: [Character], at i: Int) -> (Unicode.Scalar, Int)? {
            guard i + 1 < chars.count else { return nil }
            let simple: [Character: Unicode.Scalar] = ["b": "\u{8}", "t": "\t", "n": "\n", "f": "\u{C}",
                                                       "r": "\r", "e": "\u{1B}", "\"": "\"", "\\": "\\"]
            if let scalar = simple[chars[i + 1]] { return (scalar, i + 2) }
            let digits: Int
            switch chars[i + 1] {
            case "x": digits = 2
            case "u": digits = 4
            case "U": digits = 8
            default: return nil
            }
            guard i + 2 + digits <= chars.count else { return nil }
            let hex = String(chars[(i + 2)..<(i + 2 + digits)])
            guard hex.allSatisfy(\.isHexDigit), let value = UInt32(hex, radix: 16),
                  let scalar = Unicode.Scalar(value) else { return nil }
            return (scalar, i + 2 + digits)
        }

        static func path(_ raw: String) -> [String] {
            var parts: [String] = [], part = "", quote: Character?, escaped = false
            for c in raw {
                if let q = quote {
                    part.append(c)
                    if escaped { escaped = false }
                    else if q == "\"" && c == "\\" { escaped = true }
                    else if c == q { quote = nil }
                } else if c == "\"" || c == "'" { quote = c; part.append(c) }
                else if c == "." { parts.append(part); part = "" }
                else { part.append(c) }
            }
            parts.append(part)
            return parts.map { string($0) ?? $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    struct Table {
        var statements: [Statement]
        var path: [String] { statements.first?.header?.path ?? [] }
        var array: Bool { statements.first?.header?.array ?? false }
        var values: [String: String] {
            var result: [String: String] = [:]
            for statement in statements {
                if let (key, value) = statement.assignment { result[key] = value }
            }
            return result
        }
        var text: String { statements.map(\.text).joined() }
    }

    static func tables(_ text: String) -> [Table] {
        var result = [Table(statements: [])]
        for statement in statements(text) {
            if statement.header != nil { result.append(Table(statements: [])) }
            result[result.count - 1].statements.append(statement)
        }
        return result
    }

    /// Split only at top-level newlines. A table-looking line inside a multiline string or
    /// array is data, never a table to edit. Keep comments in `text`, but out of `code`.
    static func statements(_ text: String) -> [Statement] { scan(text).statements }

    /// Whether every bracket and brace outside a string or comment closes what it opened, and no
    /// string is left open. Otherwise `statements` has lost its place: a stray `]` takes the depth
    /// below zero and the rest of the file reads as one statement, hiding every later header.
    /// Codex and Grok both reject such a file, so an editor has no business appending to it.
    static func isBalanced(_ text: String) -> Bool { scan(text).balanced }

    private static func scan(_ text: String) -> (statements: [Statement], balanced: Bool) {
        let chars = Array(text)
        var result: [Statement] = [], raw = "", code = ""
        var quote: Character?, multiline = false, escaped = false, comment = false, depth = 0, i = 0
        var balanced = true
        func emit() {
            result.append(Statement(text: raw, code: code.trimmingCharacters(in: .whitespacesAndNewlines)))
            raw = ""; code = ""
        }
        while i < chars.count {
            let c = chars[i]
            raw.append(c)
            if comment {
                if c.isNewline { comment = false; if depth == 0 { emit() } else { code.append(c) } }
                i += 1; continue
            }
            if let q = quote {
                code.append(c)
                if escaped { escaped = false }
                else if q == "\"" && c == "\\" { escaped = true }
                else if c == q {
                    if !multiline { quote = nil }
                    else if i + 2 < chars.count, chars[i + 1] == q, chars[i + 2] == q {
                        // Four/five closing quotes include one/two literal quotes in the value.
                        var extra = 2
                        while extra < 4 && i + extra + 1 < chars.count && chars[i + extra + 1] == q { extra += 1 }
                        raw += String(repeating: String(q), count: extra)
                        code += String(repeating: String(q), count: extra)
                        i += extra; quote = nil; multiline = false
                    }
                }
            } else if c == "#" { comment = true }
            else {
                code.append(c)
                if c == "\"" || c == "'" {
                    quote = c
                    multiline = i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                    if multiline {
                        raw += String(repeating: String(c), count: 2)
                        code += String(repeating: String(c), count: 2)
                        i += 2
                    }
                } else if c == "[" || c == "{" { depth += 1 }
                else if c == "]" || c == "}" {
                    depth -= 1
                    if depth < 0 { balanced = false }
                }
                else if c.isNewline && depth == 0 { emit() }
            }
            i += 1
        }
        if !raw.isEmpty { emit() }
        return (result, balanced && depth == 0 && quote == nil)
    }
}
