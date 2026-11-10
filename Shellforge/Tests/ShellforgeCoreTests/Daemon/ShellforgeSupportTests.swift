import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// The installed app keeps today's folder and port; a dev build run with `-suite` gets a folder and a
/// port of its own, so its helper never adopts or fights the installed app's.
@Suite struct ShellforgeSupportTests {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    var installedFolder: String { "/Users/example/Library/Application Support/Shellforge" }
    var devFolder: URL { home.appendingPathComponent("Library/Application Support/example-dev", isDirectory: true) }

    @Test func theInstalledAppsFolderKeepsTodaysPathsAndPort() {
        let support = ShellforgeSupport.default(home: home)
        #expect(support.isDefault)
        #expect(support.folder.path == installedFolder)
        #expect(support.socketPath == installedFolder + "/shellforged.sock")
        #expect(support.daemonLogURL.path == installedFolder + "/shellforged.log")
        #expect(support.hookPortURL.path == installedFolder + "/hook-port")
        #expect(support.statusLineOriginalURL.path == installedFolder + "/statusline-original.cmd")
        #expect(support.grokStatusLineOriginalURL.path == installedFolder + "/grok-statusline-original.cmd")
        #expect(support.hookPort == 47831)
        #expect(ShellforgePaths.hookPortURL(home: home) == support.hookPortURL)
    }

    /// iTerm2's data folder is the executable's name; macOS folder names ignore case, so the same
    /// folder spelled otherwise, or with a trailing slash, is still the installed app's.
    @Test func theSameFolderSpelledOtherwiseIsStillTheDefault() {
        for path in [installedFolder + "/", "/Users/example/Library/Application Support/shellforge"] {
            let support = ShellforgeSupport(folder: URL(fileURLWithPath: path, isDirectory: true), home: home)
            #expect(support.isDefault, "\(path)")
            #expect(support.hookPort == ShellforgeSupport.defaultHookPort)
        }
    }

    @Test func aDevBuildsFolderHasItsOwnPathsAndAnotherPort() {
        let support = ShellforgeSupport(folder: devFolder, home: home)
        #expect(!support.isDefault)
        #expect(support.socketPath == devFolder.path + "/shellforged.sock")
        #expect(support.daemonLogURL.deletingLastPathComponent().path == devFolder.path)
        #expect(support.hookPortURL.deletingLastPathComponent().path == devFolder.path)
        #expect(support.statusLineOriginalURL.deletingLastPathComponent().path == devFolder.path)
        #expect(support.hookPort != ShellforgeSupport.defaultHookPort && support.hookPort != 47821)
        #expect(ShellforgeSupport.derivedPorts.contains(support.hookPort))
        // The same on every launch: the shims' file and the helper agree without a lookup.
        #expect(ShellforgeSupport(folder: devFolder, home: home).hookPort == support.hookPort)
    }

    @Test func everySessionCarriesTheFolder() {
        #expect(ShellforgeSupport(folder: devFolder, home: home).sessionEnvironment == ["SHELLFORGE_SUPPORT": devFolder.path])
        #expect(ShellforgeSupport.default(home: home).sessionEnvironment == ["SHELLFORGE_SUPPORT": installedFolder])
    }

    /// The helper is started with the folder's own socket, port and `--support-dir`.
    @Test func theHelperIsStartedInTheFolder() {
        let support = ShellforgeSupport(folder: devFolder, home: home)
        #expect(DaemonSupervisor.arguments(supportDirectory: support.folder, socketPath: support.socketPath, hookPort: support.hookPort)
                == ["-m", "shellforged", "run", "--support-dir", devFolder.path, "--socket", devFolder.path + "/shellforged.sock",
                    "--hook-port", String(support.hookPort)])
    }

    /// Installing Claude's hooks from a dev build records its port in its own folder, and points the
    /// hooks at that port; the installed app's folder is not touched.
    @Test func aDevBuildRecordsItsPortInItsOwnFolder() throws {
        let home = TestScratch.root.appendingPathComponent("sf-support-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let hooksFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hooks")
        let support = ShellforgeSupport(folder: home.appendingPathComponent("Library/Application Support/example-dev"), home: home)
        let hooks = HookIntegrations(home: home, support: support,
                                     resources: HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil))
        try hooks.install("claude")
        #expect(try String(contentsOf: support.hookPortURL, encoding: .utf8) == "\(support.hookPort)\n")
        #expect(!FileManager.default.fileExists(atPath: ShellforgePaths.supportDirectory(home: home).path))
        let settings = try String(contentsOf: home.appendingPathComponent(".claude/settings.json"), encoding: .utf8)
        #expect(settings.contains("127.0.0.1:\(support.hookPort)/hook/claude"))
        #expect(hooks.probe("claude").state == .current)
    }
}
