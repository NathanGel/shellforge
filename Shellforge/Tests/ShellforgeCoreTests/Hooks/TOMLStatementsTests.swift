// Ported from AiTerm (app/Tests/AiTermCoreTests/TOMLStatementsTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeCore

@Suite struct TOMLStatementsTests {
    let text = """
        # top comment
        model = "gpt-5.6"

        [ui]
        yolo = false # trailing

        [ui.status_line]
        type = "command"
        command = '~/bin/line.sh'
        padding = 2
        note = \"\"\"
        [not.a.table]
        \"\"\"
        """

    @Test func tablesSplitAtHeadersOnly() {
        let tables = TOMLStatements.tables(text)
        #expect(tables.map(\.path) == [[], ["ui"], ["ui", "status_line"]])
        #expect(tables[2].values["type"] == "command")
        #expect(tables[2].values["command"] == "~/bin/line.sh")
        #expect(tables.map(\.text).joined() == text)
    }

    @Test func keyIsTheAssignedNameEvenForNonStringValues() {
        let keys = TOMLStatements.tables(text)[2].statements.compactMap(\.key)
        #expect(keys == ["type", "command", "padding", "note"])
    }
}

/// The parser's edge cases, directly: each is a way a real config can be written that a line
/// scanner would split, or read, wrongly.
@Suite struct TOMLStatementsEdgeCaseTests {
    typealias Statement = TOMLStatements.Statement

    @Test func aHeaderMayCarryATrailingComment() {
        let tables = TOMLStatements.tables("[profiles.fast] # quick\nmodel = \"m\"\n")
        #expect(tables.map(\.path) == [[], ["profiles", "fast"]])
        #expect(tables[1].values["model"] == "m")
    }

    @Test func arrayHeadersAndQuotedOrSpacedHeaderKeys() {
        let text = "[[hooks.Stop]]\n[ ui . \"status.line\" ]\n['a b'.c]\n"
        let tables = TOMLStatements.tables(text).dropFirst()
        #expect(tables.map(\.path) == [["hooks", "Stop"], ["ui", "status.line"], ["a b", "c"]])
        #expect(tables.map(\.array) == [true, false, false])
    }

    @Test func aMultiLineArrayWithCommentsHoldingBracketsAndQuotesIsOneStatement() {
        let text = "list = [\n  \"a\", # not ] the end\n  'b', # nor \" this\n]\n[next]\n"
        #expect(TOMLStatements.statements(text).first?.text == "list = [\n  \"a\", # not ] the end\n  'b', # nor \" this\n]\n")
        #expect(TOMLStatements.tables(text).map(\.path) == [[], ["next"]])
    }

    /// TOML 1.1 lets an inline table span lines; a newline inside it does not end the statement.
    @Test func anInlineTableSpanningLinesIsOneStatement() {
        let text = "status_line = {\n  type = \"command\",\n  command = \"x\",\n}\nafter = 1\n"
        #expect(TOMLStatements.statements(text).compactMap(\.key) == ["status_line", "after"])
    }

    @Test func aMultiLineLiteralStringMayHoldQuotesOfItsOwn() {
        let text = "note = '''it's ''quoted'' '''\n[t]\n"
        #expect(TOMLStatements.statements(text).first?.value == "it's ''quoted'' ")
        #expect(TOMLStatements.tables(text).map(\.path) == [[], ["t"]])
    }

    @Test(arguments: [
        (#""plain""#, "plain"),
        (#""tab\there""#, "tab\there"),
        ("\"literal\ttab\"", "literal\ttab"),
        (#""quote \" and \\ back""#, #"quote " and \ back"#),
        (#""\b\f\n\r\e""#, "\u{8}\u{C}\n\r\u{1B}"),
        (#""\u00e9 \U0001F600 \x41""#, "é 😀 A"),
        (#"'C:\no\escapes'"#, #"C:\no\escapes"#),
        ("\"\"\"\nfirst newline trimmed\"\"\"", "first newline trimmed"),
        ("\"\"\"\r\ncrlf too\"\"\"", "crlf too"),
        ("\"\"\"one \\\n    two\"\"\"", "one two"),
        ("\"\"\"ends in two quotes\"\"\"\"\"", "ends in two quotes\"\""),
        ("'''\nraw \\n here'''", "raw \\n here"),
        ("''''one quote''''", "'one quote'"),
        ("\"\"", ""),
        ("''", ""),
        ("\"\"\"\"\"\"", ""),
    ])
    func stringReadsEveryTOMLForm(raw: String, value: String) {
        #expect(Statement.string(raw) == value)
    }

    @Test(arguments: [
        "bare", "42", "true", "[\"a\"]", "{ a = 1 }",
        #""unterminated"#, #""bad \q escape""#, #""\uD800""#,
        "\"line\nbreak\"", "'a' 'b'", "\"\"\"a\"\"\"\"\"\"", "'''open",
    ])
    func stringRejectsWhatIsNotOneTOMLString(raw: String) {
        #expect(Statement.string(raw) == nil)
    }

    @Test func keyPathSplitsDottedKeysAndReadsQuotedParts() {
        func path(_ code: String) -> [String]? { TOMLStatements.statements(code).first?.keyPath }
        #expect(path("ui . status_line.type = 1") == ["ui", "status_line", "type"])
        #expect(path("\"ui\".'status_line' = {}") == ["ui", "status_line"])
        #expect(path("\"a=b\" = 1") == ["a=b"])
        #expect(path("\"a.b\" = 1") == ["a.b"])
        #expect(path("[header]") == nil)
        #expect(path("# comment") == nil)
    }

    @Test func keyIsNilForADottedKeyButValueStillReadsIt() {
        let statement = TOMLStatements.statements("a.b = \"c\"").first
        #expect(statement?.key == nil && statement?.assignment == nil)
        #expect(statement?.value == "c")
    }
}
