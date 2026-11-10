// Ported from AiTerm (app/Tests/AiTermCoreTests/StatusLineShimTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct BundledHooksTests {
    static let hooks = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks")

    /// The shims spell the support folder in shell and nothing else of the app's: this pins that
    /// spelling, the app's `SHELLFORGE_SUPPORT` else the installed app's folder, to `ShellforgeSupport`,
    /// which writes the files they read. The status-line shims read the user's original command from
    /// the installed app's folder whatever the variable says. The port is in no bundled
    /// file, and PI's extension takes it from the driver (`PiHooks.portPlaceholder`).
    @Test func theBundledFilesSpellTheSupportFolderAsShellforgePathsDoesAndNoPort() throws {
        let relative = ShellforgePaths.supportDirectory(home: URL(fileURLWithPath: "/h")).path.replacingOccurrences(of: "/h/", with: "")
        let variable = ShellforgeSupport.environmentVariable
        let spellings = ["shellforge-claude-statusline.sh": "INSTALLED=\"$HOME/\(relative)\"\nSUPPORT=\"${\(variable):-$INSTALLED}\"",
                         "shellforge-grok-statusline.sh": "INSTALLED=\"$HOME/\(relative)\"\nSUPPORT=\"${\(variable):-$INSTALLED}\"",
                         "shellforge-status": "SUPPORT=\"${\(variable):-$HOME/\(relative)}\""]
        for (name, spelling) in spellings {
            let text = try String(contentsOf: Self.hooks.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains(spelling), "\(name) reads files from another folder than the app writes")
            if name.hasSuffix(".sh") { #expect(text.contains("ORIG_FILE=\"$INSTALLED/"), "\(name) reads the original from the app's folder") }
            #expect(text.contains(ShellforgePaths.hookPortURL(home: URL(fileURLWithPath: "/h")).lastPathComponent))
            #expect(!text.contains(String(ShellforgePaths.hookPort)), "\(name) spells the hook port")
        }
        let extensionText = try String(contentsOf: Self.hooks.appendingPathComponent("pi-shellforge-status.ts"), encoding: .utf8)
        #expect(!extensionText.contains(String(ShellforgePaths.hookPort)))
        #expect(extensionText.components(separatedBy: PiHooks.portPlaceholder).count == 2)
        #expect(extensionText.hasPrefix("// Shellforge PI extension schema: \(PiHooks.schemaVersion)\n"))
    }
}
