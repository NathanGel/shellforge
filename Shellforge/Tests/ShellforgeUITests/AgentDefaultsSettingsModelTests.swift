import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite struct AgentDefaultsSettingsModelTests {
    private let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: ["low", "medium", "high"], defaultEffort: "high")
    private let sonnet = AgentModel(id: "sonnet", label: "Sonnet", detail: nil, efforts: ["low", "high"], defaultEffort: "low")

    private func settings(defaults: UserDefaults, remembered: [String: String] = [:]) -> AgentDefaultsSettingsModel {
        AgentDefaultsSettingsModel(agents: [AgentPresets.claude], catalogue: { [opus, sonnet] _ in [opus, sonnet] },
                                   remembered: remembered, defaults: defaults)
    }

    @Test func aCardShowsTheDefaultNewTaskWouldUse() async {
        let model = settings(defaults: ScratchDefaults.make(), remembered: ["claude": "sonnet"])
        await model.load()
        #expect(model.rows[0].preference == ModelPreference(model: "sonnet", reasoning: "low"))
        #expect(!model.isSaved("claude"))
    }

    @Test func onlyAPickedDefaultIsSaved() async {
        let defaults = ScratchDefaults.make()
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
        let model = settings(defaults: ScratchDefaults.make())
        await model.load()
        model.select(sonnet, for: "claude")
        #expect(model.rows[0].preference == ModelPreference(model: "sonnet", reasoning: "high"), "a level both offer is kept")
        model.selectReasoning("medium", for: "claude")
        #expect(model.rows[0].preference == ModelPreference(model: "sonnet", reasoning: "high"))
    }

    @Test func aSavedModelThatIsGoneIsShownAsMissing() async {
        let defaults = ScratchDefaults.make()
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
