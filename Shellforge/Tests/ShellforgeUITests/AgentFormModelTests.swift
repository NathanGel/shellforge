import Combine
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Settings › Agents' form: what it says as you type, what Save writes to the file and to the
/// Keychain, the exact-status lines, and Test.
@MainActor @Suite struct AgentFormModelTests {
    private typealias Variable = AgentFormModel.Variable
    private typealias Secret = AgentFormModel.Secret

    /// The ready-made agents the app ships, from the package's own `hooks/agents`.
    private static let shippedReadyMade = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("hooks/agents", isDirectory: true)

    @Test func problemsShowAsYouType() throws {
        let fixture = try AgentSettingsFixture()
        let form = fixture.list().addForm()
        #expect(form.nameProblem == "Give the agent a name.")
        #expect(form.commandProblem == "Enter the command that starts the agent.")
        #expect(!form.canSave)

        form.name = "claude code"
        #expect(form.nameProblem == "Another agent is already called “claude code”.")
        form.name = "Local"
        #expect(form.nameProblem == nil)

        form.command = "nothere --fast"
        #expect(form.commandProblem == "Local isn’t installed. Install it, then click Reload in Settings › Core › Environment.")
        form.command = "mytool --say 'hello"
        #expect(form.commandProblem == "The command has an unclosed quote.")
        form.command = "mytool --a\u{7}"
        #expect(form.commandProblem == AgentCommand.UnsafeWord(field: "arguments", reason: .control).errorDescription)
        form.command = "mytool 'a\\b'"
        #expect(form.commandProblem == AgentCommand.UnsafeWord(field: "arguments", reason: .backslash).errorDescription)
        form.command = "mytool --fast"
        #expect(form.commandProblem == nil)

        form.promptArguments = "-p"
        #expect(form.promptProblem == "Put {prompt} where the prompt goes, for example -p {prompt}.")
        form.promptArguments = "-p {prompt}"
        #expect(form.promptProblem == nil)

        form.environment = [Variable(id: UUID(), name: "1BAD", value: "x")]
        #expect(form.variableProblem == "“1BAD” isn’t a valid variable name.")
        form.environment = [Variable(id: UUID(), name: "MODE", value: "a")]
        form.secrets = [Secret(id: UUID(), name: "MODE", value: "b", stored: false)]
        #expect(form.variableProblem == "“MODE” is set twice.")
        form.secrets = []
        form.environment = [Variable(id: UUID(), name: "OPENAI_API_KEY", value: "sk-1")]
        #expect(form.variableProblem == "“OPENAI_API_KEY” looks like a secret. Move it to Secrets, so it’s kept in the Keychain.")
        form.environment = [Variable(id: UUID(), name: "MODE", value: "fast")]
        #expect(form.variableProblem == nil)
        #expect(form.canSave)
    }

    @Test func argumentNeedsThePlaceholder() throws {
        let fixture = try AgentSettingsFixture()
        let form = fixture.list().addForm()
        form.name = "Local"
        form.command = "mytool"
        #expect(form.promptMode == .argument && form.promptArguments == "{prompt}")
        #expect(form.promptProblem == nil)
        form.promptArguments = ""
        #expect(form.promptProblem == "Put {prompt} where the prompt goes, for example -p {prompt}.")
        #expect(!form.canSave)
        form.promptArguments = "--message={prompt}"
        try form.save()
        let saved = try fixture.file("local")
        #expect(saved["arguments"] as? [[String]] == [["--message={prompt}"]])
        #expect(saved["prompt"] as? String == "argument")
    }

    @Test func typedNeedsNone() throws {
        let fixture = try AgentSettingsFixture()
        let form = fixture.list().addForm()
        form.name = "Local"
        form.command = "mytool --yes"
        form.promptArguments = "no placeholder"
        form.promptMode = .typed
        #expect(form.promptProblem == nil)
        try form.save()
        let saved = try fixture.file("local")
        #expect(saved["prompt"] as? String == "typed")
        #expect(saved["arguments"] as? [[String]] == [["--yes"]])
        #expect(AgentFormModel.PromptMode.argument.title == "As an argument")
        #expect(AgentFormModel.PromptMode.typed.title == "Typed in after it starts")
        #expect(AgentFormModel.PromptMode.none.title == "None")
        #expect(AgentFormModel.StatusMode.automatic.title == "Automatic")
        #expect(AgentFormModel.StatusMode.exact.title == "Exact")
    }

    @Test func addUsesCreateAndAFreshId() throws {
        let fixture = try AgentSettingsFixture()
        let form = fixture.list().addForm()
        form.name = "Shell"
        form.command = "mytool"
        try form.save()
        #expect(fixture.hasFile("shell-2"), "`shell` is reserved")
        #expect(fixture.changes == 1)
        // Saved once, the form edits what it made: a second Save writes the same file.
        form.command = "mytool --again"
        try form.save()
        #expect(try fixture.file("shell-2")["arguments"] as? [[String]] == [["--again"]])
    }

    @Test func secretNeverInTheFile() throws {
        let fixture = try AgentSettingsFixture()
        let form = fixture.list().addForm()
        form.name = "Local"
        form.command = "mytool"
        form.secrets = [Secret(id: UUID(), name: "LOCAL_TOKEN", value: "v4lue-never-written", stored: false)]
        try form.save()
        let text = try fixture.fileText("local")
        #expect(!text.contains("v4lue-never-written"))
        #expect((try fixture.file("local")["secrets"] as? [String: String])?.keys.sorted() == ["LOCAL_TOKEN"])
        #expect(fixture.secrets.get("agent.local.LOCAL_TOKEN") == "v4lue-never-written")
        #expect(form.secrets.map(\.value) == [""], "a saved value is never shown back")
        #expect(form.secrets.map(\.stored) == [true])

        // Opened again, the secret is there, its value not.
        let again = fixture.list().editForm("local")
        #expect(again.secrets.map(\.name) == ["LOCAL_TOKEN"] && again.secrets.map(\.value) == [""] && again.secrets.map(\.stored) == [true])
        // A Save that leaves the value empty keeps the stored one.
        try again.save()
        #expect(fixture.secrets.get("agent.local.LOCAL_TOKEN") == "v4lue-never-written")
    }

    @Test func renamedSecretMovesItsItem() throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", secrets: ["OLD_TOKEN": "agent.mine.OLD_TOKEN"]))
        fixture.secrets.set("agent.mine.OLD_TOKEN", "t0k")
        let form = fixture.list().editForm("mine")
        form.secrets[0].name = "NEW_TOKEN"
        try form.save()
        #expect(fixture.secrets.get("agent.mine.OLD_TOKEN") == nil)
        #expect(fixture.secrets.get("agent.mine.NEW_TOKEN") == "t0k")
        #expect((try fixture.file("mine")["secrets"] as? [String: String])?.keys.sorted() == ["NEW_TOKEN"])
    }

    /// I3: a hand-written file that names its own Keychain item keeps naming it through a Save that
    /// leaves the secret alone; renamed, its value moves from that item to the form's.
    @Test func aHandWrittenItemNameSurvivesASave() throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", secrets: ["TOKEN": "agent.shared.TOKEN"]))
        fixture.secrets.set("agent.shared.TOKEN", "t0k")
        let form = fixture.list().editForm("mine")
        form.name = "Mine Renamed"
        try form.save()
        #expect((try fixture.file("mine")["secrets"] as? [String: String]) == ["TOKEN": "agent.shared.TOKEN"])
        #expect(fixture.secrets.get("agent.shared.TOKEN") == "t0k")

        let again = fixture.list().editForm("mine")
        again.secrets[0].name = "NEW_TOKEN"
        try again.save()
        #expect((try fixture.file("mine")["secrets"] as? [String: String]) == ["NEW_TOKEN": "agent.mine.NEW_TOKEN"])
        #expect(fixture.secrets.get("agent.mine.NEW_TOKEN") == "t0k")
        #expect(fixture.secrets.get("agent.shared.TOKEN") == "t0k", "an item the file named may be shared: it stays")
    }

    @Test func droppedSecretIsDeleted() throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool",
                                                  secrets: ["A_TOKEN": "agent.mine.A_TOKEN", "B_TOKEN": "agent.mine.B_TOKEN"]))
        fixture.secrets.set("agent.mine.A_TOKEN", "a")
        fixture.secrets.set("agent.mine.B_TOKEN", "b")
        let form = fixture.list().editForm("mine")
        form.secrets.removeAll { $0.name == "A_TOKEN" }
        try form.save()
        #expect(fixture.secrets.get("agent.mine.A_TOKEN") == nil)
        #expect(fixture.secrets.get("agent.mine.B_TOKEN") == "b")
    }

    @Test func secretLookingVariableRefused() throws {
        let fixture = try AgentSettingsFixture()
        let form = fixture.list().addForm()
        form.name = "Local"
        form.command = "mytool"
        form.environment = [Variable(id: UUID(), name: "GITHUB_TOKEN", value: "ghp_x")]
        #expect(!form.canSave)
        #expect(throws: (any Error).self) { try form.save() }
        #expect(!fixture.hasFile("local"))
        // Empty, it is no secret to keep.
        form.environment[0].value = ""
        #expect(form.variableProblem == nil)
    }

    @Test func keychainFailureSaysSoAndKeepsTheForm() throws {
        final class RefusingStore: SecretStore {
            func get(_ key: String) -> String? { nil }
            func set(_ key: String, _ value: String?) -> Bool { value == nil }
        }
        let fixture = try AgentSettingsFixture()
        let list = AgentListModel(registry: fixture.registry, secrets: RefusingStore(), launcher: fixture.launcher, tasks: { [] },
                                  prompter: fixture.prompter, tools: fixture.tools, store: fixture.sessions.eraseToAnyPublisher(),
                                  changed: {})
        let form = list.addForm()
        form.name = "Local"
        form.command = "mytool"
        form.secrets = [Secret(id: UUID(), name: "LOCAL_TOKEN", value: "v", stored: false)]
        #expect(throws: AgentFormModel.KeychainRefused(variable: "LOCAL_TOKEN")) { try form.save() }
        #expect(AgentFormModel.KeychainRefused(variable: "LOCAL_TOKEN").errorDescription
                == "Shellforge couldn’t keep LOCAL_TOKEN in the Keychain. Enter it again and click Save.")
        #expect(form.secrets.map(\.value) == ["v"], "the value stays, to try again")
        #expect(!fixture.hasFile("local"), "nothing is saved while a secret isn’t")
    }

    @Test func aRefusedRenameNeverLosesTheSecret() throws {
        final class Refuses: SecretStore {
            var values: [String: String] = [:]
            let refused: String
            init(_ refused: String) { self.refused = refused }
            func get(_ key: String) -> String? { values[key] }
            func set(_ key: String, _ value: String?) -> Bool {
                guard key != refused else { return false }
                values[key] = value
                return true
            }
        }
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", secrets: ["OLD_TOKEN": "agent.mine.OLD_TOKEN"]))
        let store = Refuses("agent.mine.NEW_TOKEN")
        store.values["agent.mine.OLD_TOKEN"] = "t0k"
        var changes = 0
        let list = AgentListModel(registry: fixture.registry, secrets: store, launcher: fixture.launcher, tasks: { [] },
                                  prompter: fixture.prompter, tools: fixture.tools, store: fixture.sessions.eraseToAnyPublisher(),
                                  changed: { changes += 1 })
        let form = list.editForm("mine")
        form.secrets[0].name = "NEW_TOKEN"
        #expect(throws: AgentFormModel.KeychainRefused(variable: "NEW_TOKEN")) { try form.save() }
        #expect(store.values["agent.mine.OLD_TOKEN"] == "t0k", "the old item is still there")
        #expect((try fixture.file("mine")["secrets"] as? [String: String])?.keys.sorted() == ["OLD_TOKEN"], "the file still names it")
        #expect(form.secrets.map(\.stored) == [false], "the Keychain holds nothing under the new name")
        #expect(changes == 0)
        // A second Save doesn't pass for a success.
        #expect(throws: (any Error).self) { try form.save() }
        #expect(store.values["agent.mine.OLD_TOKEN"] == "t0k")
        #expect(changes == 0)
    }

    /// A Keychain in memory that refuses to write the items in `refused`.
    private final class PickyStore: SecretStore {
        var values: [String: String]
        var refused: Set<String> = []
        /// Writes refused besides `refused`'s: a key and the value it would be set to.
        var refuses: (String, String?) -> Bool = { _, _ in false }
        private(set) var refusals: [String] = []
        init(_ values: [String: String]) { self.values = values }
        func get(_ key: String) -> String? { values[key] }
        func set(_ key: String, _ value: String?) -> Bool {
            guard !refused.contains(key), !refuses(key, value) else { refusals.append(key); return false }
            values[key] = value
            return true
        }
    }

    /// The agent `mine`, its file naming `names`, edited in a form over `store`.
    private func form(names: [String], store: PickyStore, fixture: AgentSettingsFixture) throws -> AgentFormModel {
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool",
                                                  secrets: Dictionary(uniqueKeysWithValues: names.map { ($0, "agent.mine.\($0)") })))
        let list = AgentListModel(registry: fixture.registry, secrets: store, launcher: fixture.launcher, tasks: { [] },
                                  prompter: fixture.prompter, tools: fixture.tools, store: fixture.sessions.eraseToAnyPublisher(),
                                  changed: {})
        return list.editForm("mine")
    }

    private func rename(_ form: AgentFormModel, _ from: String, to: String) {
        guard let index = form.secrets.firstIndex(where: { $0.name == from }) else { return }
        form.secrets[index].name = to
    }

    @Test func aChainOfRenamesKeepsEachValue() throws {
        let fixture = try AgentSettingsFixture()
        let store = PickyStore(["agent.mine.A": "a", "agent.mine.B": "b"])
        let form = try form(names: ["A", "B"], store: store, fixture: fixture)
        rename(form, "B", to: "C")
        rename(form, "A", to: "B")
        try form.save()
        #expect(store.values == ["agent.mine.B": "a", "agent.mine.C": "b"])
    }

    @Test func aSwapKeepsEachValue() throws {
        let fixture = try AgentSettingsFixture()
        let store = PickyStore(["agent.mine.A": "a", "agent.mine.B": "b"])
        let form = try form(names: ["A", "B"], store: store, fixture: fixture)
        rename(form, "A", to: "X")
        rename(form, "B", to: "A")
        rename(form, "X", to: "B")
        try form.save()
        #expect(store.values == ["agent.mine.A": "b", "agent.mine.B": "a"])
    }

    @Test func aChainRefusedHalfwayLeavesEveryItemAsItWas() throws {
        let fixture = try AgentSettingsFixture()
        let store = PickyStore(["agent.mine.A": "a", "agent.mine.B": "b"])
        store.refused = ["agent.mine.C"]
        let form = try form(names: ["A", "B"], store: store, fixture: fixture)
        rename(form, "B", to: "C")   // the second row: refused, after the first row has written B
        rename(form, "A", to: "B")
        #expect(form.secrets.map(\.name) == ["B", "C"])
        #expect(throws: AgentFormModel.KeychainRefused(variable: "C")) { try form.save() }
        #expect(store.values == ["agent.mine.A": "a", "agent.mine.B": "b"])
        #expect(store.refusals == ["agent.mine.C"], "the refused item is written once, and not put back")
        #expect((try fixture.file("mine")["secrets"] as? [String: String])?.keys.sorted() == ["A", "B"])
    }

    @Test func anItemThatCantBePutBackIsNamed() throws {
        let fixture = try AgentSettingsFixture()
        let store = PickyStore(["agent.mine.A": "a", "agent.mine.B": "b"])
        store.refused = ["agent.mine.C"]
        // B takes A's value, then refuses to have its own back.
        store.refuses = { key, value in key == "agent.mine.B" && value == "b" }
        let form = try form(names: ["A", "B"], store: store, fixture: fixture)
        rename(form, "B", to: "C")
        rename(form, "A", to: "B")
        let expected = AgentFormModel.NotPutBack(cause: "Shellforge couldn’t keep C in the Keychain. Enter it again and click Save.",
                                                 variables: ["B"])
        #expect(throws: expected) { try form.save() }
        #expect(expected.errorDescription == "Shellforge couldn’t keep C in the Keychain. Enter it again and click Save. "
                + "Shellforge couldn’t put back B in the Keychain. Check it in the agent’s form.")
        #expect((try fixture.file("mine")["secrets"] as? [String: String])?.keys.sorted() == ["A", "B"], "the file is as it was")
    }

    /// M4: one name is “it”, several “them”; a cause with no full stop of its own still ends its
    /// sentence before the next, and an empty cause leaves no stray space.
    @Test func notPutBackReadsAsSentences() {
        typealias N = AgentFormModel.NotPutBack
        #expect(N(cause: "The file couldn’t be saved", variables: ["A", "B"]).errorDescription
                == "The file couldn’t be saved. Shellforge couldn’t put back A and B in the Keychain. Check them in the agent’s form.")
        #expect(N(cause: "Disk full.  ", variables: ["A"]).errorDescription
                == "Disk full. Shellforge couldn’t put back A in the Keychain. Check it in the agent’s form.")
        #expect(N(cause: "Is the disk full?", variables: ["A"]).errorDescription
                == "Is the disk full? Shellforge couldn’t put back A in the Keychain. Check it in the agent’s form.")
        #expect(N(cause: "", variables: ["A"]).errorDescription
                == "Shellforge couldn’t put back A in the Keychain. Check it in the agent’s form.")
    }

    @Test func aRefusedSaveWhoseUndoIsRefusedNamesIt() throws {
        let fixture = try AgentSettingsFixture()
        let store = PickyStore([:])
        // A new agent named for a reserved id is refused by the registry, after its secret was written.
        store.refuses = { key, value in key == "agent.local.LOCAL_TOKEN" && value == nil }
        let list = AgentListModel(registry: fixture.registry, secrets: store, launcher: fixture.launcher, tasks: { [] },
                                  prompter: fixture.prompter, tools: fixture.tools, store: fixture.sessions.eraseToAnyPublisher(),
                                  changed: {})
        let form = list.addForm()
        form.name = "Local"
        form.command = "mytool"
        form.secrets = [Secret(name: "LOCAL_TOKEN", value: "v", stored: false)]
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.folder.appendingPathComponent("local.json"))
        #expect(throws: AgentFormModel.NotPutBack(cause: AgentRegistry.Refusal.idTaken("local").localizedDescription,
                                                  variables: ["LOCAL_TOKEN"])) { try form.save() }
    }

    @Test func anItemThereBeforeIsPutBackNotDeleted() throws {
        let fixture = try AgentSettingsFixture()
        let store = PickyStore(["agent.mine.X": "orphan"])
        store.refused = ["agent.mine.Y"]
        let form = try form(names: [], store: store, fixture: fixture)
        form.secrets = [Secret(name: "X", value: "x", stored: false), Secret(name: "Y", value: "y", stored: false)]
        #expect(throws: AgentFormModel.KeychainRefused(variable: "Y")) { try form.save() }
        #expect(store.values == ["agent.mine.X": "orphan"])
    }

    @Test func aSecretWithoutValueOrAVariableWithoutNameIsAProblem() throws {
        let fixture = try AgentSettingsFixture()
        let form = fixture.list().addForm()
        form.name = "Local"
        form.command = "mytool"
        form.secrets = [Secret(name: "LOCAL_TOKEN", value: "", stored: false)]
        #expect(form.variableProblem == "Enter a value for LOCAL_TOKEN.")
        #expect(!form.canSave)
        form.secrets = [Secret(name: "LOCAL_TOKEN", value: "", stored: true)]
        #expect(form.variableProblem == nil, "a stored secret keeps its value")
        form.secrets = [Secret(name: "", value: "v", stored: false)]
        #expect(form.variableProblem == "A variable has a value but no name.")
        form.secrets = []
        form.environment = [Variable(name: "", value: "x")]
        #expect(form.variableProblem == "A variable has a value but no name.")
    }

    @Test func keepsHandWrittenFields() throws {
        let fixture = try AgentSettingsFixture()
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: true)
        let written = #"""
        {"id": "hand", "name": "Hand", "command": "mytool", "arguments": [["-m", "{model}"], ["--x"], ["-p", "{prompt}"], ["--y"]],
         "prompt": "argument", "models": {"command": {"_0": ["mytool", "models"]}}, "reasoningLevels": ["low", "high"],
         "defaultReasoning": "low", "environment": {}, "secrets": {}, "status": {"openTelemetry": {}}, "x-note": "keep"}
        """#
        try Data(written.utf8).write(to: fixture.folder.appendingPathComponent("hand.json"))
        let form = fixture.list().editForm("hand")
        #expect(form.command == "mytool -m {model} --x --y")
        #expect(form.promptArguments == "-p {prompt}")
        form.name = "Hand renamed"
        try form.save()
        let saved = try fixture.file("hand")
        #expect(saved["name"] as? String == "Hand renamed")
        #expect(saved["x-note"] as? String == "keep")
        #expect(saved["arguments"] as? [[String]] == [["-m", "{model}"], ["--x"], ["-p", "{prompt}"], ["--y"]],
                "untouched, the groups keep their order")
        #expect(saved["reasoningLevels"] as? [String] == ["low", "high"])
        #expect(saved["defaultReasoning"] as? String == "low")
        #expect((saved["models"] as? [String: Any])?["command"] != nil)
        #expect((saved["status"] as? [String: Any])?["openTelemetry"] != nil, "an untouched Automatic keeps its source")
    }

    @Test func builtInHasNoStatusChoice() throws {
        let fixture = try AgentSettingsFixture()
        let list = fixture.list()
        let form = list.editForm("claude")
        #expect(!form.showsStatusChoice)
        #expect(form.setupLines == nil && form.setupFile == nil && form.setupWarning == nil)
        #expect(list.addForm().showsStatusChoice)
    }

    @Test func exactShowsTheGenericLinesWithTheFullPath() throws {
        let fixture = try AgentSettingsFixture()
        fixture.tools.statusCommand = "/Applications/Shell Forge.app/Contents/Resources/hooks/shellforge-status"
        let form = fixture.list().addForm()
        form.name = "Local"
        form.command = "mytool"
        #expect(form.status == .automatic && form.setupLines == nil)
        form.status = .exact
        let quoted = "'/Applications/Shell Forge.app/Contents/Resources/hooks/shellforge-status'"
        #expect(form.setupLines == "\(quoted) working\n\(quoted) needs-input\n\(quoted) done")
        #expect(form.setupFile == nil)
        try form.save()
        #expect((try fixture.file("local")["status"] as? [String: Any])?["eventProtocol"] != nil)
    }

    @Test func readyMadeShowsItsSnippet() throws {
        let fixture = try AgentSettingsFixture()
        fixture.readyMade = Self.shippedReadyMade
        let form = fixture.list().editForm("gemini")
        #expect(form.status == .exact && form.showsStatusChoice)
        #expect(form.setupFile == "~/.gemini/settings.json")
        let lines = try #require(form.setupLines)
        #expect(lines.contains(#""command": "/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-status working""#))
        #expect(!lines.contains("{shellforge-status}"))
        #expect(form.setupNote == "Merge the hooks into the existing “hooks” key of ~/.gemini/settings.json; do not replace the file or the key.")
        #expect(form.about?.contains("Antigravity CLI") == true)
        #expect(form.promptArguments == "-i {prompt}" && form.command == "gemini")
    }

    @Test func translocatedShowsWarningInsteadOfLines() throws {
        let fixture = try AgentSettingsFixture()
        fixture.tools.translocated = true
        let form = fixture.list().addForm()
        form.status = .exact
        #expect(form.setupLines == nil)
        #expect(form.setupWarning == BundleLocation.translocationWarning)
    }

    @Test func testWaitsThenArrives() async throws {
        let fixture = try AgentSettingsFixture()
        try fixture.registry.save(AgentDefinition(id: "mine", name: "Mine", command: "mytool", status: .eventProtocol))
        let list = fixture.list()
        func publish(reportedAt: Double?, agent: SessionAgent = .custom("mine")) {
            var store = SessionStore()
            store.apply(.snapshot(DaemonSnapshot(protocolVersion: 1, connected: true, sessions: [
                SessionInfo(sessionId: "s1", windowId: "w", tabIndex: 0, taskId: nil, projectId: nil, agent: agent, model: nil,
                            state: .working, title: "t", cwd: "/", reportedAt: reportedAt),
            ], usage: .empty)))
            fixture.sessions.send(store)
        }
        // The list hears the sessions on the main queue: one hop behind them there has them delivered.
        func delivered() async { await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } } }
        let opened = fixture.clock.now.timeIntervalSince1970
        publish(reportedAt: opened - 5)
        await delivered()
        let form = list.editForm("mine")
        form.test()
        #expect(form.testMessage == "No report yet. Start a task with this agent and let its hooks run.")
        publish(reportedAt: opened + 5, agent: .custom("other"))
        await delivered()
        form.test()
        #expect(form.testMessage == "No report yet. Start a task with this agent and let its hooks run.")
        publish(reportedAt: opened + 5)
        await delivered()
        form.test()
        #expect(form.testMessage == "A report arrived from a task with this agent.")
    }

    @Test func thePreviewGoesThroughTheRunner() throws {
        let fixture = try AgentSettingsFixture()
        let form = fixture.list().addForm()
        form.name = "Local"
        form.command = "mytool --fast"
        #expect(form.preview == "'/Applications/Shellforge.app/Contents/Resources/hooks/shellforge-run' local -- 'mytool' '--fast' 'Your prompt'")
    }
}
