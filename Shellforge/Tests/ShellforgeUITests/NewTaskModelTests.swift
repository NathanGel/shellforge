import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor @Suite struct NewTaskModelTests {
    private let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
    private let project = Project(name: "demo", path: FileManager.default.temporaryDirectory.appendingPathComponent("nt-\(UUID().uuidString)").path)

    private func model(available: Set<String> = ["claude", "codex", "grok", "pi"],
                       submit: @escaping @MainActor (TaskDraft) async throws -> Void = { _ in }) -> NewTaskModel {
        NewTaskModel(project: project, agents: AgentPresets.all, available: available,
                     draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil),
                     rememberedModels: [:], catalogue: { [opus] _ in [opus] }, branches: { ["main"] }, submit: submit)
    }

    @Test func theFirstStepNeedsOnlyAName() async {
        let sheet = model()
        #expect(!sheet.canAdvance(step: 1))
        sheet.draft.setTitle("Login")
        #expect(sheet.canAdvance(step: 1))
        #expect(!sheet.canAdvance(step: 2), "no model is loaded yet")
        await sheet.loadCatalogue()
        #expect(sheet.draft.model == "opus" && sheet.draft.reasoning == "high")
        #expect(sheet.canAdvance(step: 2) && sheet.canAdvance(step: 3))
    }

    @Test func aMissingAgentCannotBePickedOrCreated() async {
        let sheet = model(available: ["codex"])
        sheet.draft.setTitle("Login")
        await sheet.loadCatalogue()
        #expect(!sheet.agentIsReady && !sheet.canAdvance(step: 2))
        #expect(NewTaskModel.missingAgentNote(agents: AgentPresets.all, available: ["codex"])
                == "Claude Code, Grok Build and PI aren’t installed. Install them in Settings › Agents.")
        #expect(await sheet.create() == false)
    }

    @Test func createRunsOnceWhilePressedTwice() async {
        final class Count { var value = 0 }
        let submitted = Count()
        let sheet = model(submit: { _ in submitted.value += 1; try await Task.sleep(for: .milliseconds(50)) })
        sheet.draft.setTitle("Login")
        await sheet.loadCatalogue()
        async let first = sheet.create()
        async let second = sheet.create()
        let results = await [first, second]
        #expect(submitted.value == 1 && results.filter { $0 }.count == 1)
    }

    @Test func anInvalidBranchKeepsTheSheetOpenWithTheReason() async {
        let sheet = model(submit: { throw TaskWorktrees.Refusal.invalidBranch($0.branch) })
        sheet.draft.setTitle("Login")
        await sheet.loadCatalogue()
        #expect(await sheet.create() == false)
        #expect(sheet.error?.reason == "“feat/login” is not a valid Git branch name.")
        #expect(sheet.draft.title == "Login", "the draft survives for correction")
    }

    @Test func switchingAgentReloadsItsModels() async {
        let sheet = model()
        await sheet.loadCatalogue()
        sheet.selectAgent("codex")
        #expect(sheet.models.isEmpty && !sheet.catalogueLoaded)
        await sheet.loadCatalogue()
        #expect(sheet.draft.agentId == "codex" && sheet.draft.model == "opus")
    }

    @Test func thePreviewCarriesTheTypedPrompt() async {
        let sheet = model()
        await sheet.loadCatalogue()
        sheet.draft.promptText = "fix it"
        #expect(sheet.previewCommand == "claude --model opus --effort high 'fix it'")
    }

    /// Switching agent swaps the popup's list for the new agent's, and closes an open popup.
    @Test func switchingAgentReloadsAndClosesTheCompletions() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nt-skills-\(UUID().uuidString)")
        for (path, name) in [(".claude/skills/brainstorming", "brainstorming"), (".codex/skills/imagegen", "imagegen")] {
            let folder = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "---\nname: \(name)\n---\n".write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        let sheet = NewTaskModel(project: project, agents: AgentPresets.all, available: ["claude", "codex"],
                                 draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil),
                                 rememberedModels: [:], catalogue: { [opus] _ in [opus] }, branches: { ["main"] },
                                 submit: { _ in }, home: home)
        await sheet.loadCatalogue()
        #expect(sheet.completions.all.map(\.name) == ["brainstorming"])
        sheet.completions.visible = sheet.completions.all
        sheet.selectAgent("codex")
        await sheet.loadCatalogue()
        #expect(sheet.completions.all.map(\.name) == ["imagegen"])
        #expect(!sheet.completions.isOpen)
    }
}
