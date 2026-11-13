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

    @Test func aDevBuildsSessionsCarryItsFolder() {
        #expect(ShellforgeSupport(folder: devFolder, home: home).sessionEnvironment == ["SHELLFORGE_SUPPORT": devFolder.path])
        #expect(ShellforgeSupport.default(home: home).sessionEnvironment.isEmpty, "the installed app's tabs gain no variable")
    }

    /// The helper is started with the folder's own socket, port and `--support-dir`.
    @Test func theHelperIsStartedInTheFolder() {
        let support = ShellforgeSupport(folder: devFolder, home: home)
        #expect(DaemonSupervisor.arguments(supportDirectory: support.folder, socketPath: support.socketPath, hookPort: support.hookPort, appPid: 4242)
                == ["-m", "shellforged", "run", "--support-dir", devFolder.path, "--socket", devFolder.path + "/shellforged.sock",
                    "--hook-port", String(support.hookPort), "--app-pid", "4242"])
    }

    private static var hooksFolder: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("hooks")
    }

    private static func resources() -> HookResources {
        HookResources(folder: hooksFolder, installationAllowed: true, unavailableReason: nil)
    }

    /// A scratch home, its dev build's folder, and that build's hooks.
    private static func devBuild() -> (home: URL, support: ShellforgeSupport, hooks: HookIntegrations) {
        let home = TestScratch.root.appendingPathComponent("sf-support-\(UUID().uuidString)")
        let support = ShellforgeSupport(folder: home.appendingPathComponent("Library/Application Support/example-dev"), home: home)
        return (home, support, HookIntegrations(home: home, support: support, resources: resources()))
    }

    /// The agents' settings are global: a dev build's sheet shows the installed app's install, on
    /// 47831 and the installed app's `hook-port`, as it really is.
    @Test func aDevBuildProbesTheInstalledAppsHooks() throws {
        let (home, _, dev) = Self.devBuild()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(dev.isSharedWithInstalledApp)
        #expect(!HookIntegrations(home: home, resources: Self.resources()).isSharedWithInstalledApp)
        try HookIntegrations(home: home, resources: Self.resources()).install("claude")
        try HookIntegrations(home: home, resources: Self.resources()).install("codex")
        #expect(dev.probe("claude").state == .current)
        #expect(dev.probe("codex").state == .current)
    }

    /// A dev build's plain install is refused, and writes nothing.
    @Test func aDevBuildsInstallIsRefusedUnlessMadeForThisBuild() throws {
        let (home, _, dev) = Self.devBuild()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(throws: HookIntegrationError.sharedWithInstalledApp) { try dev.install("claude") }
        #expect(!FileManager.default.fileExists(atPath: home.path))
        #expect(HookIntegrationError.sharedWithInstalledApp.errorDescription == HookIntegrations.sharedExplanation)
    }

    /// Made for this build anyway, the install records the build's port in its own folder and points
    /// the hooks at it; the user's own status line is still recorded in the installed app's folder,
    /// which describes the global settings file, so the installed app's shim keeps running it.
    @Test func aDevBuildsInstallForThisBuildUsesItsPortAndKeepsTheOriginalGlobal() throws {
        let (home, support, dev) = Self.devBuild()
        defer { try? FileManager.default.removeItem(at: home) }
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"my-own-line"}}"#.utf8).write(to: settingsURL)
        try dev.install("claude", forThisBuild: true)
        #expect(try String(contentsOf: support.hookPortURL, encoding: .utf8) == "\(support.hookPort)\n")
        let settings = try String(contentsOf: settingsURL, encoding: .utf8)
        #expect(settings.contains("127.0.0.1:\(support.hookPort)/hook/claude"))
        let installed = ShellforgeSupport.default(home: home)
        #expect(try String(contentsOf: installed.statusLineOriginalURL, encoding: .utf8) == "my-own-line")
        #expect(!FileManager.default.fileExists(atPath: support.statusLineOriginalURL.path))
        #expect(!FileManager.default.fileExists(atPath: installed.hookPortURL.path))
        // The installed app's hooks are now elsewhere, so the sheet says so.
        #expect(dev.probe("claude").state != .current)
    }
}
