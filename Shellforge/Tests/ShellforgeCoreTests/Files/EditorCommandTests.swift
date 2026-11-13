import XCTest
@testable import ShellforgeCore

final class EditorCommandTests: XCTestCase {
    func testTheSettingWins() {
        XCTAssertEqual(EditorCommand.editor(setting: "  code -w ", environment: ["EDITOR": "nvim"]), "code -w")
    }

    func testEditorEnvironmentIsNext() {
        XCTAssertEqual(EditorCommand.editor(setting: nil, environment: ["EDITOR": "nvim"]), "nvim")
    }

    func testTheFallbackIsVi() {
        XCTAssertEqual(EditorCommand.editor(setting: nil, environment: [:]), "vi")
        XCTAssertEqual(EditorCommand.editor(setting: nil, environment: ["EDITOR": " "]), "vi")
    }

    func testBlankSettingIsIgnored() {
        XCTAssertEqual(EditorCommand.editor(setting: "  ", environment: ["EDITOR": "nvim"]), "nvim")
    }

    func testOddFileNamesAreQuoted() throws {
        XCTAssertEqual(try EditorCommand.command(editor: "vim", file: "my file's $x.md").line, #"vim -- './my file'\''s $x.md'"#)
        XCTAssertEqual(try EditorCommand.command(editor: "vim", file: "ünïcode.txt").line, "vim -- './ünïcode.txt'")
        XCTAssertEqual(try EditorCommand.command(editor: "nvim -p", file: "src/app.ts").line, "nvim -p -- ./src/app.ts")
    }
}
