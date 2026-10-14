import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The error banner's ×: the error stays until it is dismissed or a later action succeeds.
@MainActor @Suite struct DismissErrorTests {
    private func model() -> SidebarModel {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("dismiss-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
    }

    @Test func dismissingClearsTheError() {
        let model = model()
        model.lastError = "Couldn’t create Fix login."
        model.dismissError()
        #expect(model.lastError == nil)
    }

    @Test func dismissingForgetsWhosePullFailureWasShown() {
        let model = model()
        let project = UUID()
        model.lastError = "Couldn’t pull main."
        model.shownPullError = (project, "Couldn’t pull main.")
        model.dismissError()
        #expect(model.shownPullError == nil)
    }
}
