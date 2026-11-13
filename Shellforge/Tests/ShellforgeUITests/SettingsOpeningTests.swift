import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Settings and New Task as they open: nothing that may wait — the login shell, a Keychain prompt —
/// runs on the main actor, and what Settings saves goes to the suite it was given.
@MainActor @Suite struct SettingsOpeningTests {
    private func document(in root: URL) -> WorkspaceDocument {
        WorkspaceDocument(store: WorkspaceStore(folder: root.appendingPathComponent("workspace")))
    }

    /// The launcher's login shell answers only once the test opens the gate; a read on the main
    /// thread answers at once and is noted, so a regression fails here rather than hanging.
    @Test func settingsOpensWithoutWaitingForTheShell() async throws {
        let fixture = try AgentSettingsFixture(installed: ["claude"])
        let gate = DispatchGroup()
        gate.enter()
        let readOnMain = Locked(false)
        let path = fixture.bin.path
        let launcher = CommandLauncher(resolve: {
            if Thread.isMainThread { readOnMain.withLock { $0 = true } } else { gate.wait() }
            return ResolvedEnvironment(variables: ["PATH": path], source: .loginShell("/bin/zsh"))
        })
        let model = SidebarModel(host: FakeTerminalHost(), document: document(in: fixture.root), launcher: launcher)
        // What Settings makes as it opens, before the shell has answered.
        let agentDefaults = model.agentDefaultsModel(defaults: MemoryDefaults.make())
        let list = AgentListModel(registry: fixture.registry, secrets: fixture.secrets, launcher: launcher, tasks: { [] },
                                  prompter: fixture.prompter, tools: fixture.tools, store: fixture.sessions.eraseToAnyPublisher(),
                                  changed: {})
        #expect(!readOnMain.withLock { $0 }, "the main actor waited for the login shell")
        #expect(agentDefaults.finding && agentDefaults.rows.isEmpty)
        #expect(list.rows.contains { $0.id == "claude" })
        #expect(list.rows.allSatisfy { $0.installed == nil }, "unknown, not “not installed”, until the shell answers")
        gate.leave()
        await agentDefaults.load()
        #expect(!agentDefaults.finding)
        #expect(agentDefaults.rows.map(\.id) == ["claude"])
        await eventually(describing: "Claude Code shown as installed") { list.rows.first { $0.id == "claude" }?.installed == true }
        #expect(!readOnMain.withLock { $0 })
    }

    /// New Task's and Settings' saved connections are Keychain reads: each runs off the main actor.
    @Test func sheetsReadSecretsOffTheMainActor() async throws {
        let repo = try await GitRepoForUI()
        let reads = Locked<[Bool]>([])
        let model = SidebarModel(host: FakeTerminalHost(), document: document(in: URL(fileURLWithPath: repo.path).deletingLastPathComponent()),
                                 launcher: repo.launcher,
                                 jiraSettings: { reads.withLock { $0.append(Thread.isMainThread) }; return nil },
                                 gitLabSettings: { reads.withLock { $0.append(Thread.isMainThread) }; return nil },
                                 gitHubSettings: { reads.withLock { $0.append(Thread.isMainThread) }; return nil })
        await model.addProject(folder: repo.path)
        let project = try #require(model.document.workspace.projects.first).id
        reads.withLock { $0 = [] }
        #expect(await model.prepareNewTask(for: project) != nil)
        #expect(await model.integrationSettings(defaults: MemoryDefaults.make()) != nil)
        let made = reads.withLock { $0 }
        #expect(made.count == 4, "New Task reads Jira; Settings reads all three")
        #expect(!made.contains(true), "a secret was read on the main actor")
    }

    /// Settings' Services save to the suite the app hands in, and the store beside it.
    @Test func settingsSaveToTheSuiteTheyAreGiven() async throws {
        let root = TestScratch.root.appendingPathComponent("settings-suite-\(UUID().uuidString)")
        let secrets = MemorySecretStore(), suite = MemoryDefaults.make()
        let model = SidebarModel(host: FakeTerminalHost(), document: document(in: root),
                                 launcher: CommandLauncher { ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin"], source: .loginShell("/bin/sh")) },
                                 secrets: secrets)
        let settings = try #require(await model.integrationSettings(defaults: suite))
        let jira = JiraConfig(siteURL: URL(string: "https://example.atlassian.net")!, email: "dev@example.com", token: "t0ken")
        settings.jira.fields = JiraFields(jira)
        #expect(settings.save() == nil)
        #expect(suite.string(forKey: "jira.site") == "https://example.atlassian.net")
        #expect(JiraSettings.load(store: secrets, defaults: suite) == jira)
    }
}
