import ShellforgeCore
@testable import ShellforgeTestSupport
import XCTest
@testable import ShellforgeUI

@MainActor
final class TerminalEditorSettingsTests: XCTestCase {
    private func make(_ store: UserDefaults, editor: String? = nil) -> TerminalEditorSettings {
        TerminalEditorSettings(defaults: store, environment: { editor.map { ["EDITOR": $0] } ?? [:] })
    }

    func testSaveTrimsAndKeepsOneLine() {
        let store = ScratchDefaults.make()
        make(store).save("  code -w\n--new-window  ")
        XCTAssertEqual(store.string(forKey: EditorCommand.settingKey), "code -w --new-window")
        XCTAssertEqual(make(store).saved, "code -w --new-window")
    }

    func testAnEmptyDraftRemovesTheKey() {
        let store = ScratchDefaults.make()
        store.set("nvim", forKey: EditorCommand.settingKey)
        make(store).save(" \n ")
        XCTAssertNil(store.object(forKey: EditorCommand.settingKey))
    }

    func testThePlaceholderFollowsTheLoad() async {
        let settings = make(ScratchDefaults.make(), editor: "nvim")
        XCTAssertEqual(settings.placeholder, "vi")
        XCTAssertEqual(settings.emptyStatus, "Uses vi")
        await settings.load()
        XCTAssertEqual(settings.placeholder, "$EDITOR (nvim)")
        XCTAssertEqual(settings.emptyStatus, "From $EDITOR")
    }

    func testNoEditorStaysVi() async {
        let settings = make(ScratchDefaults.make())
        await settings.load()
        XCTAssertEqual(settings.placeholder, "vi")
    }
}
