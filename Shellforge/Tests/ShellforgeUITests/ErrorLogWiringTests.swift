import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// What the sidebar tells the person goes in the error log too, for whoever reports a bug later.
@MainActor @Suite struct ErrorLogWiringTests {
    private func model() -> SidebarModel {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("error-wiring-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
    }

    private func lines(_ log: ErrorLog) -> [String] {
        let text = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Every error the sidebar shows is recorded, under `sidebar`; clearing it records nothing.
    @Test func eachSidebarErrorIsRecorded() {
        let log = ErrorLog(folder: TestScratch.root.appendingPathComponent("error-wiring-log-\(UUID().uuidString)"), version: "0.9.1")
        let model = model()
        ErrorLogging.$testLog.withValue(log) {
            model.lastError = "Couldn’t create Fix login."
            model.lastError = nil
            model.lastError = "Couldn’t pull main.\nfatal: no upstream"
        }
        let written = lines(log)
        #expect(written.count == 2)
        #expect(written.first?.hasSuffix(" · 0.9.1 · sidebar · Couldn’t create Fix login.") == true)
        #expect(written.last?.hasSuffix(" · 0.9.1 · sidebar · Couldn’t pull main. ⏎ fatal: no upstream") == true)
    }
}
