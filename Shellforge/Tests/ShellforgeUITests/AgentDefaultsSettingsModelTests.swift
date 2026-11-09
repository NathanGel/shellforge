import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Every verdict here reads back a default the test wrote, so the defaults are in memory
/// (`MemoryDefaults`): no cfprefsd round trip, however loaded the run.
@MainActor @Suite struct AgentDefaultsSettingsModelTests {
    private let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high")
    private let sonnet = AgentModel(id: "sonnet", label: "Sonnet", detail: nil, efforts: ["low", "high"], defaultEffort: "low")

    private func settings(defaults: UserDefaults, remembered: [String: String] = [:]) -> AgentDefaultsSettingsModel {
        AgentDefaultsSettingsModel(agents: [AgentPresets.claude], catalogue: { [opus, sonnet] _ in [opus, sonnet] },
                                   remembered: remembered, defaults: defaults)
    }

    /// Settings › Agents added an agent: its row comes, and a pick made in another row stays.
    @Test func anAgentAddedInSettingsJoinsTheList() async {
        let model = settings(defaults: MemoryDefaults.make())
        await model.load()
        model.selectReasoning("medium", for: "claude")
        let mine = AgentDefinition(id: "mine", name: "Mine", command: "mytool")
        model.update(agents: [AgentPresets.claude, mine])
        #expect(model.rows.map(\.id) == ["claude", "mine"])
        #expect(!model.rows[1].loaded)
        await model.load(onlyUnloaded: true)
        #expect(model.rows[1].loaded)
        #expect(model.rows[0].preference?.reasoning == "medium" && model.isSaved("claude"))
        model.update(agents: [AgentPresets.claude])
        #expect(model.rows.map(\.id) == ["claude"])
    }

    /// T: a read still on its way when Settings › Agents changes the agent is for the agent as it
    /// was: it never lands on the changed agent's row, which is read again. The catalogue blocks on
    /// a gate the test opens, so the order is fixed, not timed.
    @Test func aReadOfAnAgentSinceChangedIsDropped() async {
        let before = AgentDefinition(id: "mine", name: "Mine", command: "old", models: .fixed([]))
        var after = before
        after.command = "new"
        let gate = DispatchSemaphore(value: 0)
        let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
        let model = AgentDefaultsSettingsModel(agents: [before], catalogue: { [opus, sonnet] agent in
            guard agent.command == "old" else { return [sonnet] }
            enteredContinuation.yield()
            gate.wait()
            return [opus]
        }, remembered: [:], defaults: MemoryDefaults.make())
        let first = Task { await model.load() }
        var iterator = entered.makeAsyncIterator()
        await iterator.next()
        model.update(agents: [after])
        gate.signal()
        await first.value
        #expect(!model.rows[0].loaded && model.rows[0].models.isEmpty, "the old agent's read is dropped")
        await model.load(onlyUnloaded: true)
        #expect(model.rows[0].loaded && model.rows[0].models == [sonnet])
    }

    @Test func aCardShowsTheDefaultNewTaskWouldUse() async {
        let model = settings(defaults: MemoryDefaults.make(), remembered: ["claude": "sonnet"])
        await model.load()
        #expect(model.rows[0].preference == ModelPreference(model: "sonnet", reasoning: "low"))
        #expect(!model.isSaved("claude"))
    }

    @Test func onlyAPickedDefaultIsSaved() async {
        let defaults = MemoryDefaults.make()
        let untouched = settings(defaults: defaults)
        await untouched.load()
        untouched.save()
        #expect(ModelSettings.load(for: "claude", defaults: defaults) == nil, "a resolved default is not pinned")

        let model = settings(defaults: defaults)
        await model.load()
        model.selectReasoning("medium", for: "claude")
        #expect(ModelSettings.load(for: "claude", defaults: defaults) == nil, "nothing is written before Save")
        model.save()
        #expect(ModelSettings.load(for: "claude", defaults: defaults) == ModelPreference(model: "opus", reasoning: "medium"))
    }

    @Test func aReasoningTheModelDoesNotOfferIsIgnored() async {
        let model = settings(defaults: MemoryDefaults.make())
        await model.load()
        model.select(sonnet, for: "claude")
        #expect(model.rows[0].preference == ModelPreference(model: "sonnet", reasoning: "high"), "a level both offer is kept")
        model.selectReasoning("medium", for: "claude")
        #expect(model.rows[0].preference == ModelPreference(model: "sonnet", reasoning: "high"))
    }

    @Test func aSavedModelThatIsGoneIsShownAsMissing() async {
        let defaults = MemoryDefaults.make()
        ModelSettings.save(ModelPreference(model: "gone", reasoning: "high"), for: "claude", defaults: defaults)
        let model = settings(defaults: defaults)
        await model.load()
        #expect(model.rows[0].missing)
        model.select(opus, for: "claude")
        model.save()
        #expect(ModelSettings.load(for: "claude", defaults: defaults) == ModelPreference(model: "opus", reasoning: "high"))
    }

    @Test func newTaskOpensWithTheSavedDefault() async {
        let sheet = NewTaskModel(project: Project(name: "demo", path: TestScratch.root.appendingPathComponent("ad-\(UUID().uuidString)").path),
                                 agents: AgentPresets.all, available: ["claude"],
                                 draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil),
                                 rememberedModels: ["claude": "opus"],
                                 modelDefaults: ["claude": ModelPreference(model: "sonnet", reasoning: "high")],
                                 catalogue: { [opus, sonnet] _ in [opus, sonnet] }, branches: { ["main"] }, submit: { _ in },
                                 home: TestScratch.root.appendingPathComponent("ad-home-\(UUID().uuidString)"))
        await sheet.loadCatalogue()
        #expect(sheet.draft.model == "sonnet" && sheet.draft.reasoning == "high")
    }
}
