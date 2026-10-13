import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// What the review of Backpack Mode's port found: its children must not pass for the app, and a
/// Shellforge that dies with lid sleep off must not leave the Mac sleepless until its next launch.
@Suite(.serialized) struct BackpackSafetyTests {
    /// AiTerm's ProcessRunner strips the launch identity: `osascript` otherwise checked in with
    /// LaunchServices as the app and showed a second Dock icon.
    @Test func childrenDoNotCarryTheAppsLaunchIdentity() throws {
        setenv("__CFBundleIdentifier", "io.github.nathangel.shellforge", 1)
        defer { unsetenv("__CFBundleIdentifier") }
        let out = try BackpackProcess.run(URL(fileURLWithPath: "/usr/bin/env"), [], timeout: 5)
        #expect(!out.stdout.contains("__CFBundleIdentifier"))
    }

    /// The watchdog waits on a pipe the app holds and runs its command once the pipe closes — when
    /// the app lets it go, or when the app dies however it dies.
    @Test func theWatchdogRunsItsCommandWhenItsHolderGoes() async throws {
        let file = TestScratch.root.appendingPathComponent("sf-watchdog-\(UUID().uuidString)").path
        let watchdog = SleepWatchdog(command: ["/bin/sh", "-c", "/bin/cat >/dev/null; /usr/bin/touch '\(file)'"])
        watchdog.arm()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: file), "armed, it waits")
        watchdog.disarm()
        await eventually { FileManager.default.fileExists(atPath: file) }
    }

    /// The live lid-sleep port arms the watchdog when it turns lid sleep off, and lets it go when it
    /// turns lid sleep back on.
    @Test func lidSleepOffArmsTheWatchdogAndOnLetsItGo() {
        let watchdog = RecordingWatchdog()
        let lid = SudoLidSleep(watchdog: watchdog, run: { _ in true })
        #expect(lid.setDisabled(true))
        #expect(watchdog.events == ["arm"])
        #expect(lid.setDisabled(false))
        #expect(watchdog.events == ["arm", "disarm"])
    }
}

final class RecordingWatchdog: SleepWatchdogging, @unchecked Sendable {
    private(set) var events: [String] = []
    func arm() { events.append("arm") }
    func disarm() { events.append("disarm") }
}
