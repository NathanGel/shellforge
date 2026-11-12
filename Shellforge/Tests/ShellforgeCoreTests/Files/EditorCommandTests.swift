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

    func testOddFileNamesAreQuoted() {
        XCTAssertEqual(EditorCommand.line(editor: "vim", file: "my file's $x.md"), #"exec vim 'my file'\''s $x.md'"#)
        XCTAssertEqual(EditorCommand.line(editor: "vim", file: "ünïcode.txt"), "exec vim 'ünïcode.txt'")
        XCTAssertEqual(EditorCommand.line(editor: "nvim -p", file: "src/app.ts"), "exec nvim -p src/app.ts")
    }
}
