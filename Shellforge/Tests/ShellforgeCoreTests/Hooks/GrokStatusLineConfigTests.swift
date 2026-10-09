// Ported from AiTerm (app/Tests/AiTermCoreTests/GrokStatusLineConfigTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct GrokStatusLineConfigTests {
    let shim = "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-grok-statusline.sh"
    let ours = "[ui.status_line]\ntype = \"command\"\ncommand = \"/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-grok-statusline.sh\"\n"

    @Test func addsATableWhenThereIsNone() throws {
        let text = "[cli]\ninstaller = \"internal\"\n\n[ui]\nyolo = false\n"
        #expect(GrokStatusLineConfig.state(text, shimPath: shim) == .missing)
        let merged = try #require(GrokStatusLineConfig.merge(text, shimPath: shim))
        #expect(merged.text == text + "\n" + ours)
        #expect(merged.replaced == nil)
        #expect(GrokStatusLineConfig.state(merged.text, shimPath: shim) == .current)
        #expect(GrokStatusLineConfig.merge(merged.text, shimPath: shim) == nil)
    }

    @Test func missingFileGetsOnlyTheTable() throws {
        #expect(try #require(GrokStatusLineConfig.merge(nil, shimPath: shim)).text == ours)
    }

    @Test(arguments: ["disabled", "off", "none", "hidden"])
    func replacesADisabledTableKeepingItsOtherKeys(type: String) throws {
        let text = "# mine\n[ui.status_line]\ntype = \"\(type)\"\npadding = 2 # keep\n\n[other]\nx = 1\n"
        let merged = try #require(GrokStatusLineConfig.merge(text, shimPath: shim))
        #expect(merged.text == "# mine\n[ui.status_line]\ntype = \"command\"\ncommand = \"\(shim)\"\npadding = 2 # keep\n\n[other]\nx = 1\n")
    }

    @Test func wrapsAForeignCommandAndSavesIt() throws {
        let text = "[ui.status_line]\ntype = \"command\"\ncommand = \"~/.grok/statusline.sh\"\nrefresh_interval = 60\n"
        #expect(GrokStatusLineConfig.state(text, shimPath: shim) == .foreign("~/.grok/statusline.sh"))
        let merged = try #require(GrokStatusLineConfig.merge(text, shimPath: shim))
        #expect(merged.replaced == "~/.grok/statusline.sh")
        #expect(merged.text == "[ui.status_line]\ntype = \"command\"\ncommand = \"\(shim)\"\nrefresh_interval = 60\n")
    }

    @Test func repointsOurShimFromAMovedBundle() throws {
        let text = "[ui.status_line]\ntype = \"command\"\ncommand = \"/Users/me/Downloads/Shellforge.app/Contents/Resources/hooks/shellforge-grok-statusline.sh\"\n"
        #expect(GrokStatusLineConfig.state(text, shimPath: shim) == .outdated)
        let merged = try #require(GrokStatusLineConfig.merge(text, shimPath: shim))
        #expect(merged.replaced == nil && merged.text == ours)
    }

    @Test func leavesABuiltinStatusLineAlone() {
        let text = "[ui.status_line]\ntype = \"builtin\"\nitems = [\"cwd\", \"context\"]\n"
        #expect(GrokStatusLineConfig.state(text, shimPath: shim) == .builtin)
        #expect(GrokStatusLineConfig.merge(text, shimPath: shim) == nil)
    }

    @Test(arguments: [
        "[ui]\nstatus_line = { type = \"builtin\" }\n",
        "[ui]\nstatus_line.type = \"builtin\"\n",
        "ui.status_line.type = \"builtin\"\n",
        "[ui.status_line]\ntype = \"fancy\"\n",
    ])
    func leavesLayoutsItCannotEditAlone(text: String) {
        #expect(GrokStatusLineConfig.state(text, shimPath: shim) == .unsupportedLayout)
        #expect(GrokStatusLineConfig.merge(text, shimPath: shim) == nil)
    }

    /// What a TOML parser such as Grok's (or Python's `tomllib`) counts as declaring `path`: its
    /// own header, an assignment to it, or a dotted key through it. Two declarations fail the
    /// whole file ("Cannot declare ('ui', 'status_line') twice").
    static func declarations(of path: [String], in text: String) -> Int {
        TOMLStatements.tables(text).reduce(0) { count, table in
            let header = table.path == path && !table.array ? 1 : 0
            let keys = table.path == path ? 0 : table.statements.compactMap(\.keyPath)
                .filter { (table.path + $0).starts(with: path) }.count
            return count + header + keys
        }
    }

    /// Every way to write the status line other than one plain `[ui.status_line]` table, and
    /// every file where appending that table would declare it twice, is left alone.
    @Test(arguments: [
        "[ui]\n\"status_line\" = { type = \"command\", command = \"x\" }\n",
        "ui . status_line.type = \"command\"\n",
        "\"ui\".status_line.type = \"command\"\n",
        "ui  = { status_line = { type = \"command\" } }\n",
        "ui = { yolo = true }\n",
        "[[ui.status_line]]\ntype = \"command\"\n",
        "[ui.status_line]\ntype = \"command\"\n[ui.status_line.extra]\nx = 1\n",
        "[ui.status_line]\ntype = \"command\"\n[ui.status_line]\ntype = \"disabled\"\n",
    ])
    func leavesEveryOtherStatusLineLayoutAlone(text: String) {
        #expect(GrokStatusLineConfig.state(text, shimPath: shim) == .unsupportedLayout)
        #expect(GrokStatusLineConfig.merge(text, shimPath: shim) == nil)
    }

    /// Whatever a merge writes declares the status line exactly once.
    @Test(arguments: [
        "", "[ui]\nyolo = false\n", "[ui]\nstatus_line_width = 3\n", "ui.status_line_width = 3\n",
        "[ui.status_line]\ntype = \"disabled\"\n",
        "[ui . \"status_line\"] # mine\ntype = \"command\"\ncommand = \"~/x.sh\"\n",
    ])
    func aMergeNeverDeclaresTheStatusLineTwice(text: String) throws {
        let merged = try #require(GrokStatusLineConfig.merge(text, shimPath: shim))
        #expect(Self.declarations(of: ["ui", "status_line"], in: merged.text) == 1)
        #expect(GrokStatusLineConfig.state(merged.text, shimPath: shim) == .current)
    }

    @Test func aKeyThatOnlyStartsLikeTheStatusLineIsNotIt() {
        #expect(GrokStatusLineConfig.state("[ui]\nstatus_line_width = 3\n", shimPath: shim) == .missing)
        #expect(GrokStatusLineConfig.state("ui.status_line_width = 3\n", shimPath: shim) == .missing)
    }

    @Test(arguments: [
        ("command = \"\"\"\n~/line.sh\"\"\"", "~/line.sh"),
        ("command = '''~/it's.sh'''", "~/it's.sh"),
        (#"command = "~/a\tb.sh --x \U0001F600""#, "~/a\tb.sh --x 😀"),
        ("command = \"~/tab\there.sh\"", "~/tab\there.sh"),
    ])
    func readsACommandInEveryStringForm(line: String, command: String) throws {
        let text = "[ui.status_line]\ntype = \"command\"\n\(line)\n"
        #expect(GrokStatusLineConfig.state(text, shimPath: shim) == .foreign(command))
        #expect(try #require(GrokStatusLineConfig.merge(text, shimPath: shim)).replaced == command)
    }

    /// A `command` or `type` AiTerm cannot read is not a missing one: taking it for missing would
    /// drop the user's command from the table and delete the saved original.
    @Test(arguments: [
        "type = \"command\"\ncommand = [\"~/line.sh\"]\n",
        "type = \"command\"\ncommand = 42\n",
        "type = \"command\"\ncommand.path = \"~/line.sh\"\n",
        "type = 1\ncommand = \"~/line.sh\"\n",
    ])
    func anUnreadableCommandOrTypeLeavesTheTableAlone(body: String) {
        let text = "[ui.status_line]\n" + body
        #expect(GrokStatusLineConfig.state(text, shimPath: shim) == .unsupportedLayout)
        #expect(GrokStatusLineConfig.merge(text, shimPath: shim) == nil)
    }

    @Test func quotesAShimPathWithSpaces() throws {
        let spaced = "/Users/me/My Apps/Shellforge.app/Contents/Resources/hooks/shellforge-grok-statusline.sh"
        let merged = try #require(GrokStatusLineConfig.merge(nil, shimPath: spaced))
        #expect(merged.text.contains("command = \"'\(spaced)'\""))
        #expect(GrokStatusLineConfig.state(merged.text, shimPath: spaced) == .current)
    }
}
