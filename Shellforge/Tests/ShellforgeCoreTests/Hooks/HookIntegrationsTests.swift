import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

@Suite struct HookIntegrationsTests {
    private func home() throws -> URL {
        let dir = TestScratch.root.appendingPathComponent("sf-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The package's own hooks folder, as the app bundles it.
    private var hooksFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hooks")
    }

    @Test func everyPresetIsProbedAndNothingIsInstalledUntilAsked() throws {
        let home = try home()
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        #expect(hooks.agents == ["claude", "codex", "grok", "pi"])
        #expect(hooks.agents.map { hooks.probe($0).state } == [.missing, .missing, .missing, .missing])
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    @Test func installingOneTouchesOnlyItsOwnFiles() throws {
        let home = try home()
        let hooks = HookIntegrations(home: home, resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        try hooks.install("codex")
        #expect(hooks.probe("codex").state == .current)
        #expect(hooks.probe("claude").state == .missing)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
    }

    @Test func aTranslocatedBundleCannotInstall() throws {
        let hooks = HookIntegrations(home: try home(), resources: .bundled(resourceURL:
            URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Shellforge.app/Contents/Resources")))
        #expect(hooks.probe("claude").state == .resourceUnavailable)
        #expect(throws: (any Error).self) { try hooks.install("claude") }
    }
}
