import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Settings › Agents' world in a scratch folder: an agents folder, a ready-made folder, a `bin` on the
/// launcher's `PATH` holding the commands said to be installed, the Keychain in memory, a scripted
/// prompter, the session feed and a clock.
@MainActor
final class AgentSettingsFixture {
    let root = TestScratch.root.appendingPathComponent("agent-settings-\(UUID().uuidString)")
    var folder: URL { root.appendingPathComponent("agents") }
    var readyMadeFolder: URL { root.appendingPathComponent("ready-made") }
    var bin: URL { root.appendingPathComponent("bin") }
    let secrets = MemorySecretStore()
    let prompter = ScriptedPrompter([])
    let sessions = PassthroughSubject<SessionStore, Never>()
    let clock = TestClock(Date(timeIntervalSince1970: 1_000_000))
    var tasks: [TaskItem] = []
    var changes = 0
    var tools = AgentTools(statusCommand: "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-status",
                           runner: URL(fileURLWithPath: "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-run"),
                           readyMade: nil, translocated: false)
    var readyMade: URL?
    lazy var registry = AgentRegistry(folder: folder, readyMade: readyMade, trash: { try FileManager.default.removeItem(at: $0) })
    lazy var launcher: CommandLauncher = {
        let path = bin.path
        return CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": path], source: .loginShell("/bin/zsh")) })
    }()

    init(installed: [String] = ["claude", "mytool"]) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in installed { try install(name) }
    }

    func install(_ name: String) throws {
        let file = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    /// A ready-made folder holding `agents`, written as the app ships them.
    func readyMade(_ agents: [AgentDefinition]) throws {
        try FileManager.default.createDirectory(at: readyMadeFolder, withIntermediateDirectories: true)
        for agent in agents { try JSONEncoder().encode(agent).write(to: readyMadeFolder.appendingPathComponent("\(agent.id).json")) }
        readyMade = readyMadeFolder
    }

    func list() -> AgentListModel {
        AgentListModel(registry: registry, secrets: secrets, launcher: launcher, tasks: { [unowned self] in tasks },
                       prompter: prompter, tools: tools, store: sessions.eraseToAnyPublisher(), now: { [clock] in clock.now },
                       changed: { [unowned self] in changes += 1 })
    }

    func file(_ id: String) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("\(id).json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func fileText(_ id: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent("\(id).json"), encoding: .utf8)
    }

    func hasFile(_ id: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(id).json").path) }

    func task(_ title: String, agent: String) -> TaskItem {
        TaskItem(projectId: UUID(), title: title, branch: title, worktreePath: "/tmp/\(title)", baseBranch: "main", agent: agent)
    }
}

@MainActor @Suite struct AgentListModelTests {
    private let gemini = AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini", arguments: [["-i", "{prompt}"]],
                                         status: .eventProtocol, statusSetup: .init(file: "~/.gemini/settings.json", snippet: "x"))
    private let aider = AgentDefinition(id: "aider", name: "Aider", command: "aider", prompt: .typed)

    @Test func rowsInOrder() throws {
        let fixture = try AgentSettingsFixture()
        try fixture.readyMade([gemini, aider])
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool"))
        var codex = AgentPresets.codex
        codex.command = "mytool"
        try fixture.registry.save(codex)
        let list = fixture.list()
        #expect(list.rows.map(\.id) == ["claude", "codex", "grok", "pi", "aider", "gemini", "mine"])
        #expect(list.rows.map(\.origin) == [.builtIn, .builtIn, .builtIn, .builtIn, .readyMade, .readyMade, .own])
        #expect(list.rows.map(\.installed) == [true, true, false, false, false, false, true])
        #expect(list.rows.map(\.overridden) == [false, true, false, false, false, false, false])
        #expect(list.rows.map(\.detection) == [.builtIn, .builtIn, .builtIn, .builtIn, .automatic, .exact, .automatic])
        #expect(AgentListModel.Detection.builtIn.label == "Built-in status")
        #expect(AgentListModel.Detection.automatic.label == "Automatic status")
        #expect(AgentListModel.Detection.exact.label == "Exact status")
        #expect(list.failure == nil)
    }

    @Test func editingABuiltInMakesAnOverride() throws {
        let fixture = try AgentSettingsFixture()
        let list = fixture.list()
        let form = list.editForm("claude")
        #expect(!form.showsStatusChoice)
        form.command = "claude --verbose --model {model} --effort {reasoning}"
        try form.save()
        let saved = try fixture.file("claude")
        #expect(saved["command"] as? String == "claude")
        #expect(saved["arguments"] as? [[String]] == [["--verbose"], ["--model", "{model}"], ["--effort", "{reasoning}"]])
        let row = try #require(list.rows.first { $0.id == "claude" })
        #expect(row.origin == .builtIn && row.overridden && row.detection == .builtIn)
        #expect(row.agent.status == .preset("claude"), "a built-in keeps its own detection")
        #expect(fixture.changes == 1)
    }

    @Test func restoreDefaultRemovesTheOverrideAndItsSecrets() async throws {
        let fixture = try AgentSettingsFixture(installed: ["gemini"])
        try fixture.readyMade([gemini])
        let list = fixture.list()
        let form = list.editForm("gemini")
        form.secrets = [.init(id: UUID(), name: "GEMINI_API_KEY", value: "s3cret", stored: false)]
        try form.save()
        #expect(fixture.secrets.get("agent.gemini.GEMINI_API_KEY") == "s3cret")
        #expect(list.rows.first { $0.id == "gemini" }?.overridden == true)
        fixture.prompter.answers = [AlertAnswer(button: 0)]
        await list.restoreDefault("gemini")
        let asked = try #require(fixture.prompter.asked.last)
        #expect(asked.message == "Restore “Gemini CLI” to its default?")
        #expect(asked.detail == "Your changes to its command, environment and secrets are removed.")
        #expect(asked.buttons == ["Restore Default", "Cancel"])
        #expect(!fixture.hasFile("gemini"))
        #expect(fixture.secrets.get("agent.gemini.GEMINI_API_KEY") == nil)
        #expect(list.rows.first { $0.id == "gemini" }?.overridden == false)
        #expect(fixture.changes == 2, "the save, then the restore")
    }

    @Test func restoreDefaultCancelledKeepsTheOverride() async throws {
        let fixture = try AgentSettingsFixture()
        var claude = AgentPresets.claude
        claude.command = "mytool"
        try fixture.registry.save(claude)
        let list = fixture.list()
        fixture.prompter.answers = [AlertAnswer(button: 1)]
        await list.restoreDefault("claude")
        #expect(fixture.hasFile("claude"))
        #expect(fixture.changes == 0)
    }

    @Test func removeAsksNamingTheTasks() async throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool"))
        fixture.tasks = [fixture.task("Login", agent: "mine"), fixture.task("Other", agent: "claude"),
                         fixture.task("Search", agent: "mine"), fixture.task("Docs", agent: "mine")]
        let list = fixture.list()
        fixture.prompter.answers = [AlertAnswer(button: 1)]
        await list.remove("mine")
        let asked = try #require(fixture.prompter.asked.first)
        #expect(asked.message == "Remove “Mine”?")
        #expect(asked.detail == "These tasks use it: Login, Search and Docs. They stay in the sidebar, but can’t start Mine again.")
        #expect(asked.buttons == ["Remove", "Cancel"])
        #expect(asked.defaultDeletes)

        fixture.tasks = []
        await list.remove("mine")
        #expect(fixture.prompter.asked.last?.detail == "No task uses it.")
    }

    @Test func removeCancelledKeepsEverything() async throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", secrets: ["TOKEN": "agent.mine.TOKEN"]))
        fixture.secrets.set("agent.mine.TOKEN", "t0k")
        let list = fixture.list()
        fixture.prompter.answers = [AlertAnswer(button: 1)]
        await list.remove("mine")
        #expect(fixture.hasFile("mine"))
        #expect(fixture.secrets.get("agent.mine.TOKEN") == "t0k")
        #expect(list.rows.contains { $0.id == "mine" })
        #expect(fixture.changes == 0)
    }

    @Test func removeDeletesTheSecrets() async throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", secrets: ["TOKEN": "agent.mine.TOKEN"]))
        fixture.secrets.set("agent.mine.TOKEN", "t0k")
        fixture.secrets.set("agent.other.TOKEN", "keep")
        let list = fixture.list()
        fixture.prompter.answers = [AlertAnswer(button: 0)]
        await list.remove("mine")
        #expect(!fixture.hasFile("mine"))
        #expect(fixture.secrets.get("agent.mine.TOKEN") == nil)
        #expect(fixture.secrets.get("agent.other.TOKEN") == "keep")
        #expect(!list.rows.contains { $0.id == "mine" })
        #expect(fixture.changes == 1)
    }

    @Test func duplicateMakesAnOwnAgent() throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", secrets: ["TOKEN": "agent.mine.TOKEN"]))
        fixture.secrets.set("agent.mine.TOKEN", "t0k")
        let list = fixture.list()
        list.duplicate("claude")
        let copy = try #require(list.rows.first { $0.id == "claude-copy" })
        #expect(copy.origin == .own && copy.agent.name == "Claude Code copy" && copy.detection == .automatic)
        list.duplicate("mine")
        #expect(fixture.secrets.get("agent.mine-copy.TOKEN") == "t0k", "the copy can start as the original does")
        #expect(fixture.changes == 2)
        // The copy names its own item, not the original's, which goes when the original does.
        let copied = try #require(list.rows.first { $0.id == "mine-copy" }?.agent)
        #expect(copied.secrets == ["TOKEN": "agent.mine-copy.TOKEN"])
        #expect(try AgentSecrets.environment(for: copied, store: fixture.secrets) == ["TOKEN": "t0k"])
    }

    /// A hand-written file's own item name is copied as it is: the copy reads the same item.
    @Test func aDuplicateKeepsAHandWrittenItemName() throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", secrets: ["TOKEN": "agent.shared.TOKEN"]))
        fixture.secrets.set("agent.shared.TOKEN", "t0k")
        let list = fixture.list()
        list.duplicate("mine")
        let copied = try #require(list.rows.first { $0.id == "mine-copy" }?.agent)
        #expect(copied.secrets == ["TOKEN": "agent.shared.TOKEN"])
        #expect(list.failure == nil)
        #expect(try AgentSecrets.environment(for: copied, store: fixture.secrets) == ["TOKEN": "t0k"])
    }

    @Test func aDuplicateWhoseSecretTheKeychainRefusesSaysSo() throws {
        final class RefusesCopies: SecretStore {
            var values = ["agent.mine.TOKEN": "t0k"]
            func get(_ key: String) -> String? { values[key] }
            func set(_ key: String, _ value: String?) -> Bool {
                guard !key.hasPrefix("agent.mine-copy.") else { return false }
                values[key] = value
                return true
            }
        }
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", secrets: ["TOKEN": "agent.mine.TOKEN"]))
        var changes = 0
        let list = AgentListModel(registry: fixture.registry, secrets: RefusesCopies(), launcher: fixture.launcher, tasks: { [] },
                                  prompter: fixture.prompter, tools: fixture.tools, store: fixture.sessions.eraseToAnyPublisher(),
                                  changed: { changes += 1 })
        list.duplicate("mine")
        #expect(list.rows.contains { $0.id == "mine-copy" })
        #expect(list.failure == "The copy was made, but Shellforge couldn’t copy TOKEN to the Keychain. Set it in the copy’s form.")
        #expect(changes == 1)
    }

    @Test func aFailedChangeIsSaidAndChangesNothing() throws {
        let fixture = try AgentSettingsFixture()
        let list = fixture.list()
        list.duplicate("nope")
        #expect(list.failure == "There is no agent “nope”.")
        #expect(fixture.changes == 0)
    }

    @Test func anUnreadableFileIsSaid() throws {
        let fixture = try AgentSettingsFixture()
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.folder.appendingPathComponent("broken.json"))
        let list = fixture.list()
        #expect(list.failure == "An agent file couldn’t be read: broken.json. The other agents loaded.")
        #expect(list.rows.count == 4)
    }

    @Test func theBundledToolsAreTheAppsOwn() {
        let resources = URL(fileURLWithPath: "/Applications/Shellforge.app/Contents/Resources")
        let tools = AgentTools.bundled(resourceURL: resources, bundlePath: "/Applications/Shellforge.app")
        #expect(tools.statusCommand == "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-status")
        #expect(tools.runner?.path == "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-run")
        #expect(tools.readyMade == AgentRegistry.bundledReadyMade(resourceURL: resources))
        #expect(!tools.translocated)
        #expect(AgentTools.bundled(resourceURL: nil, bundlePath: "/private/var/folders/x/T/AppTranslocation/1/d/Shellforge.app").translocated)
        #expect(AgentTools.none.runner == nil && AgentTools.none.statusCommand == nil)
    }
}
