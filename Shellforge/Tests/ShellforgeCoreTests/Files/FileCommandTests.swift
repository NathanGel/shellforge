import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// What a file's tab runs: the login shell with a fixed script, the file's path its argument, never
/// typed. The path is never an option, never a keystroke, never code.
@Suite struct FileCommandTests {
    private static let refusal = "This file’s name has a control character in it, so it can’t be opened in a terminal."

    /// Names a cloned repository could hold, from the review: a Meta byte under bash's C locale, an
    /// option to vim, quotes, expansions, iTerm2's own `\(…)` and `$$…$$`, and odd spaces.
    static let hostile = [
        "ň$(touch PWNED);#", "\u{85}$(touch PWNED);#", "\u{9B}x", "+!touch PWNED", "-c!touch PWNED", "-", "--",
        #"a\'; touch PWNED; '.md"#, #"\(touch)"#, "$$HOME$$", "a$$$b", "\"q\"", "'", "`touch PWNED`", "~x", " lead",
        "trail ", "tab\u{A0}nbsp", "line\u{2028}sep", "\u{202E}gnp.exe", "😀.md", "café.md", "x;y|z&w", "*", "[ab]",
        "sub/-x[1].txt", "!!",
    ]

    @Test func aPlusOrDashNameIsNotAnOption() throws {
        let vi = try EditorCommand.command(editor: "vi", file: "+!touch PWNED")
        #expect(vi.paths == ["./+!touch PWNED"])
        #expect(vi.line == "vi -- './+!touch PWNED'")
        #expect(try EditorCommand.command(editor: "vim", file: "-c!touch PWNED").paths == ["./-c!touch PWNED"])
        #expect(try EditorCommand.command(editor: "/opt/homebrew/bin/nvim -p", file: "+5").line == "/opt/homebrew/bin/nvim -p -- ./+5")
        #expect(try EditorCommand.command(editor: "code -w", file: "-x.md").line == "code -w ./-x.md", "an editor not known to take -- has none")
        #expect(try EditorCommand.command(editor: "vim", file: "/tmp/-x.md").paths == ["/tmp/-x.md"], "an absolute path starts with /")
        #expect(try GitActions.diffCommand(for: GitChange(path: "-p", letter: .untracked), staged: false).paths == ["./-p"])
    }

    /// Every scalar from 0x00 to 0x1F, and DEL, at the start, the middle and the end, at the top and
    /// in a folder: refused by the editor and by every diff.
    @Test func controlCharactersAreRefused() {
        let controls = (0x00...0x1F).map { Character(Unicode.Scalar(UInt8($0))) } + [Character(Unicode.Scalar(0x7F))]
        for control in controls {
            for path in ["\(control)a.md", "a\(control)b.md", "a.md\(control)", "src/deep/a\(control)b.md"] {
                #expect(throws: FileCommand.Unsafe.self) { try EditorCommand.command(editor: "vi", file: path) }
                for staged in [false, true] {
                    #expect(throws: FileCommand.Unsafe.self) { try GitActions.diffCommand(for: GitChange(path: path, letter: .modified), staged: staged) }
                }
            }
        }
        #expect(FileCommand.Unsafe().message == Self.refusal)
        #expect(FileCommand.Unsafe().localizedDescription == Self.refusal)
    }

    /// Nothing is typed any more, so a backslash and any non-ASCII name open as they are.
    @Test func backslashAndNonASCIINamesOpen() throws {
        for path in [#"a\'b.md"#, "café.md", "ň$(touch PWNED);#.md", "\u{85}x.md"] {
            #expect(try EditorCommand.command(editor: "vi", file: path).paths == ["./" + path])
            #expect(try GitActions.diffCommand(for: GitChange(path: path, letter: .modified), staged: true).paths == [":(literal)./" + path])
        }
    }

    @Test func ordinaryNamesStillOpen() throws {
        #expect(try EditorCommand.command(editor: "vim", file: "src/app.ts").line == "vim -- ./src/app.ts")
        #expect(try EditorCommand.command(editor: "vim", file: "my file's $x.md").line == #"vim -- './my file'\''s $x.md'"#)
        #expect(try EditorCommand.command(editor: "code -w", file: "app/[id]/page.tsx").line == "code -w './app/[id]/page.tsx'")
        #expect(try GitActions.diffCommand(for: GitChange(path: "src/app.ts", letter: .modified), staged: false).line
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
            #expect(throws: FileCommand.Unsafe.self) { try GitActions.diffCommand(for: change, staged: staged) }
        }
        let diff = { try GitActions.diffCommand(for: $0, staged: $1) }
        #expect(try diff(GitChange(path: "-n.md", letter: .modified), false).line == "git diff -- ':(literal)./-n.md'")
        #expect(try diff(GitChange(path: "-n.md", letter: .modified), true).line == "git diff --staged -- ':(literal)./-n.md'")
        #expect(try diff(GitChange(path: "-n.md", originalPath: "+o.md", letter: .renamed), true).paths == [":(literal)./+o.md", ":(literal)./-n.md"])
        #expect(try diff(GitChange(path: "-n.md", letter: .untracked), false).line == "git diff --no-index -- /dev/null ./-n.md")
        #expect(try diff(GitChange(path: "a.md", letter: .modified), false).keepsShell)
    }

    /// The tab's argv: the shell's own words, the script, `$0`, then the path as one argument.
    @Test func thePathIsTheShellsArgument() throws {
        let edit = try EditorCommand.command(editor: "vim", file: "ň$(x).md")
        #expect(edit.argv(shell: "/bin/zsh") == ["/bin/zsh", "-l", "-i", "-c", #"exec vim -- "$1""#, "shellforge-open", "./ň$(x).md"])
        #expect(edit.argv(shell: "/opt/homebrew/bin/fish") == ["/opt/homebrew/bin/fish", "-l", "-i", "-c", #"exec vim -- "$argv[1]""#, "./ň$(x).md"])
        #expect(edit.argv(shell: "/bin/tcsh") == ["/bin/zsh", "-l", "-i", "-c", #"exec vim -- "$1""#, "shellforge-open", "./ň$(x).md"],
                "tcsh rejects -l with -c")
        let rename = try GitActions.diffCommand(for: GitChange(path: "b.md", originalPath: "a.md", letter: .renamed), staged: true)
        #expect(rename.argv(shell: "/bin/bash") == ["/bin/bash", "-l", "-i", "-c", #"git diff --staged -M -- "$1" "$2"; exec /bin/bash -l"#,
                                                    "shellforge-open", ":(literal)./a.md", ":(literal)./b.md"])
        #expect(rename.argv(shell: "/usr/local/bin/fish")[4] == #"git diff --staged -M -- "$argv[1]" "$argv[2]"; exec /usr/local/bin/fish -l"#)
        #expect(rename.argv(shell: "/bin/tcsh")[4].hasSuffix("; exec /bin/tcsh -l"), "the diff's tab goes on in the account's own shell")
    }

    /// Each POSIX shell here, under the C locale and UTF-8, hands the program exactly `-- ./<name>`
    /// for every hostile name, and runs nothing the name holds. (`-l -i` are left out: the test
    /// must not read this Mac's dotfiles.)
    @Test(arguments: ["/bin/zsh", "/bin/bash", "/bin/sh", "/bin/dash", "/bin/ksh"])
    func hostileNamesReachTheEditorIntact(shell: String) throws {
        let folder = TestScratch.root.appendingPathComponent("shellforge-open-\(UUID().uuidString)")
        let bin = folder.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let out = folder.appendingPathComponent("argv").path
        let vim = bin.appendingPathComponent("vim")
        try "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$ARGV_OUT\"\n".write(to: vim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vim.path)
        for locale in ["C", "en_US.UTF-8"] {
            for name in Self.hostile {
                let argv = try EditorCommand.command(editor: "vim", file: name).argv(shell: shell).filter { $0 != "-l" && $0 != "-i" }
                try? FileManager.default.removeItem(atPath: out)
                let run = try ChildProcess.run(argv[0], Array(argv.dropFirst()),
                                               environment: ["PATH": bin.path + ":/usr/bin:/bin", "ARGV_OUT": out, "LC_ALL": locale],
                                               directory: folder.path, timeout: 10)
                #expect(run.status == 0, "\(shell) \(locale) \(name): \(run.stderr)")
                let bytes = try Data(contentsOf: URL(fileURLWithPath: out))
                let received = bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
                #expect(received == ["--", "./" + name], "\(shell) \(locale)")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("PWNED").path))
    }
}
