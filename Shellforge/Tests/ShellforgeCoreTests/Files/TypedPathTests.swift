import Foundation
import Testing
@testable import ShellforgeCore

/// A file's path typed into a terminal tab, in the editor's line or a diff's: never an option,
/// never a keystroke, never a quote ended early.
@Suite struct TypedPathTests {
    private static let refusal = "This file’s name can’t be typed safely into a terminal."

    @Test func aPlusOrDashNameIsNotAnOption() throws {
        #expect(try EditorCommand.line(editor: "vi", file: "+!touch demo") == "exec vi -- './+!touch demo'")
        #expect(try EditorCommand.line(editor: "vim", file: "-c!touch demo") == "exec vim -- './-c!touch demo'")
        #expect(try EditorCommand.line(editor: "/opt/homebrew/bin/nvim -p", file: "+5") == "exec /opt/homebrew/bin/nvim -p -- ./+5")
        #expect(try EditorCommand.line(editor: "code -w", file: "-x.md") == "exec code -w ./-x.md", "an editor not known to take -- has none")
        #expect(try EditorCommand.line(editor: "vim", file: "/tmp/-x.md") == "exec vim -- /tmp/-x.md", "an absolute path starts with /")
        #expect(try GitActions.diffLine(for: GitChange(path: "-p", letter: .untracked), staged: false)
                == "git diff --no-index -- /dev/null ./-p")
    }

    @Test(arguments: ["\u{15}", "\r", "\n", "\t", "\u{1B}", "\u{7F}", "\u{0}"])
    func controlCharactersAreRefused(_ control: String) {
        for path in ["a\(control)b.md", "src/deep/a\(control)b.md"] {
            #expect(throws: TypedPath.Unsafe.self) { try EditorCommand.line(editor: "vi", file: path) }
            #expect(throws: TypedPath.Unsafe.self) { try GitActions.diffLine(for: GitChange(path: path, letter: .modified), staged: false) }
        }
    }

    @Test func aBackslashIsRefused() {
        let path = #"a\'; touch demo; '.md"#
        #expect(throws: TypedPath.Unsafe.self) { try EditorCommand.line(editor: "vi", file: path) }
        #expect(throws: TypedPath.Unsafe.self) { try GitActions.diffLine(for: GitChange(path: path, letter: .modified), staged: true) }
        #expect(TypedPath.Unsafe().message == Self.refusal)
        #expect(TypedPath.Unsafe().localizedDescription == Self.refusal)
    }

    @Test func ordinaryNamesStillOpen() throws {
        #expect(try EditorCommand.line(editor: "vim", file: "src/app.ts") == "exec vim -- ./src/app.ts")
        #expect(try EditorCommand.line(editor: "vim", file: "my file's $x.md") == #"exec vim -- './my file'\''s $x.md'"#)
        #expect(try EditorCommand.line(editor: "vim", file: "ünïcode.txt") == "exec vim -- './ünïcode.txt'")
        #expect(try EditorCommand.line(editor: "code -w", file: "app/[id]/page.tsx") == "exec code -w './app/[id]/page.tsx'")
        #expect(try GitActions.diffLine(for: GitChange(path: "src/app.ts", letter: .modified), staged: false)
                == "git diff -- ':(literal)./src/app.ts'")
    }

    /// The plain diff, the staged one, a staged rename (both its paths) and an untracked file.
    @Test func everyDiffBranchIsGuarded() throws {
        let bad = "a\u{15}b.md"
        let changes: [(GitChange, Bool)] = [
            (GitChange(path: bad, letter: .modified), false),
            (GitChange(path: bad, letter: .modified), true),
            (GitChange(path: "ok.md", originalPath: bad, letter: .renamed), true),
            (GitChange(path: bad, originalPath: "ok.md", letter: .renamed), true),
            (GitChange(path: bad, letter: .untracked), false),
        ]
        for (change, staged) in changes {
            #expect(throws: TypedPath.Unsafe.self) { try GitActions.diffLine(for: change, staged: staged) }
        }
        #expect(try GitActions.diffLine(for: GitChange(path: "-n.md", letter: .modified), staged: false) == "git diff -- ':(literal)./-n.md'")
        #expect(try GitActions.diffLine(for: GitChange(path: "-n.md", letter: .modified), staged: true) == "git diff --staged -- ':(literal)./-n.md'")
        #expect(try GitActions.diffLine(for: GitChange(path: "-n.md", originalPath: "+o.md", letter: .renamed), staged: true)
                == "git diff --staged -M -- ':(literal)./+o.md' ':(literal)./-n.md'")
        #expect(try GitActions.diffLine(for: GitChange(path: "-n.md", letter: .untracked), staged: false)
                == "git diff --no-index -- /dev/null ./-n.md")
    }
}
