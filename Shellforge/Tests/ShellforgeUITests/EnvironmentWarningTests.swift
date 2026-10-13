import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The sidebar says when Shellforge could not read the login shell's environment (PRD E6), and stops
/// saying it once a read succeeds. Launchers are scripted: no login shell runs.
@MainActor @Suite struct EnvironmentWarningTests {
    private let folder = TestScratch.root.appendingPathComponent("shellforge-envwarn-\(UUID().uuidString)")

    /// Answers a fallback until told the rc file is fixed.
    private final class Shell: @unchecked Sendable {
        let fixed = Locked(false)
        func read() -> ResolvedEnvironment {
            fixed.withLock { $0 }
                ? ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh"))
                : ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .fallback("/bin/zsh did not answer within 15 s"))
        }
    }

    private func model(_ launcher: CommandLauncher) -> SidebarModel {
        SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                     launcher: launcher, jiraSettings: { nil })
    }

    @Test func aFallbackEnvironmentWarnsAndAReadClearsIt() async {
        let shell = Shell()
        let launcher = CommandLauncher(resolve: shell.read)
        let sidebar = model(launcher)
        #expect(await eventually { sidebar.environmentWarning != nil })
        #expect(sidebar.environmentWarning == "Your login shell’s environment couldn’t be read (/bin/zsh did not answer within 15 s); "
                + "Shellforge is using a fallback PATH. Settings › Core shows it.")
        shell.fixed.withLock { $0 = true }
        launcher.reload()
        sidebar.environmentChanged()
        #expect(await eventually { sidebar.environmentWarning == nil })
    }

    @Test func aLoginShellEnvironmentWarnsNothing() async throws {
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let sidebar = model(launcher)
        #expect(await eventually { launcher.readAt != nil }, "the environment was read at start, off the main actor")
        try await Task.sleep(for: .milliseconds(50))
        #expect(sidebar.environmentWarning == nil)
    }
}
