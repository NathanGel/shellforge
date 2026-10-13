import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

@MainActor @Suite struct NewTaskModelTests {
    private let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
    private let project = Project(name: "demo", path: TestScratch.root.appendingPathComponent("nt-\(UUID().uuidString)").path)

    private func model(project: Project? = nil, available: Set<String> = ["claude", "codex", "grok", "pi"],
                       searchIssues: @escaping @MainActor (String) async throws -> [JiraTicket] = { _ in [] },
                       submit: @escaping @MainActor (TaskDraft) async throws -> Void = { _ in }) -> NewTaskModel {
        NewTaskModel(project: project ?? self.project, agents: AgentPresets.all, available: available,
                     draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil),
                     rememberedModels: [:], catalogue: { [opus] _ in [opus] }, branches: { ["main"] }, submit: submit,
                     searchIssues: searchIssues,
                     home: TestScratch.root.appendingPathComponent("nt-home-\(UUID().uuidString)"))
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
        let home = TestScratch.root.appendingPathComponent("nt-skills-\(UUID().uuidString)")
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

    /// Switching agent drops the old agent's list at once, not when the new one has loaded.
    @Test func switchingAgentDropsTheOldListAtOnce() {
        let sheet = model()
        sheet.completions.all = [AgentCompletion(name: "brainstorming", kind: .skill, detail: nil, source: .user)]
        sheet.completions.visible = sheet.completions.all
        sheet.selectAgent("codex")
        #expect(!sheet.completions.isOpen && sheet.completions.all.isEmpty)
    }

    // -- the Jira ticket field (AiTerm's TaskCreationModelTests) ----------------------------

    @Test func lateSearchCannotReplaceNewerResultsOrAPickedTicket() async throws {
        final class Pending { var byText: [String: CheckedContinuation<[JiraTicket], Error>] = [:] }
        let pending = Pending()
        let sheet = model(searchIssues: { text in try await withCheckedThrowingContinuation { pending.byText[text] = $0 } })
        let first = Task { await sheet.search(text: "old") }
        await eventually { pending.byText["old"] != nil }
        let second = Task { await sheet.search(text: "new") }
        await eventually { pending.byText["new"] != nil }
        let ticket = JiraTicket(key: "MOB-1", summary: "Newest", description: "", issueType: nil, status: nil, url: "https://example.com")
        try #require(pending.byText["new"]).resume(returning: [ticket])
        await second.value
        try #require(pending.byText["old"]).resume(returning: [])
        await first.value
        #expect(sheet.results == [ticket])
        let third = Task { await sheet.search(text: "abandoned") }
        await eventually { pending.byText["abandoned"] != nil }
        sheet.cancelSearch()
        sheet.draft.apply(ticket: ticket)
        try #require(pending.byText["abandoned"]).resume(throwing: JiraError.unauthorized)
        await third.value
        #expect(sheet.draft.ticket == ticket)
        #expect(sheet.searchError == nil)
    }

    @Test func withoutAJiraConnectionASearchSaysSo() async {
        let search = NewTaskModel.jiraSearcher(for: project, jira: nil)
        await #expect { try await search("login") } throws: {
            ($0 as? ActionUnavailable)?.message == "Connect Jira in Settings, or continue without a ticket."
        }
    }

    @Test func withoutJiraTheFieldSaysHowAndCreateStillWorks() async {
        let sheet = model(searchIssues: NewTaskModel.jiraSearcher(for: project, jira: nil))
        await sheet.search(text: "")
        #expect(sheet.searchError == "Connect Jira in Settings, or continue without a ticket.")
        sheet.draft.setTitle("Login")
        await sheet.loadCatalogue()
        #expect(await sheet.create())
    }

    @Test func thePreviewedCommandCarriesTheTicketOnlyWhenItIsIncluded() async {
        let sheet = model()
        await sheet.loadCatalogue()
        let ticket = JiraTicket(key: "ML-7", summary: "Drain the queue", description: nil,
                                issueType: "Task", status: "To Do", url: "https://example/ML-7")
        sheet.draft.apply(ticket: ticket)
        sheet.draft.promptText = "Start here."
        sheet.draft.appendTicket = true
        #expect(sheet.previewCommand.contains("ML-7: Drain the queue"))
        #expect(sheet.previewCommand.contains("Start here."))
        sheet.draft.appendTicket = false
        #expect(!sheet.previewCommand.contains("ML-7"))
    }

    /// AiTerm's theTicketFieldNamesTheLinkedJiraProjectsItSearches, and the searcher handing those
    /// projects to every query: the open-ticket list and a typed search alike.
    @Test func theTicketFieldNamesAndSearchesTheLinkedProjects() async throws {
        let site = URL(string: "https://example.atlassian.net")!
        let linked = [JiraProjectRef(id: "1", key: "SHOP", name: "Storefront", siteURL: site),
                      JiraProjectRef(id: "2", key: "PAY", name: "Payments", siteURL: site)]
        func placeholder(_ jira: [JiraProjectRef]) -> String {
            model(project: Project(name: "Repo", path: "/tmp/repo", jiraProjects: jira)).ticketPlaceholder
        }
        #expect(placeholder(linked) == "Search SHOP and PAY by key or title")
        #expect(placeholder([linked[1]]) == "Search PAY by key or title")
        #expect(placeholder([]) == "Search by key or title")

        let stub = StubSession { _ in (200, Data(#"{"issues":[]}"#.utf8)) }
        let config = JiraConfig(siteURL: site, email: "me@example.com", token: "t")
        let search = NewTaskModel.jiraSearcher(for: Project(name: "Repo", path: "/tmp/repo", jiraProjects: linked),
                                               jira: config, session: stub.session)
        _ = try await search("")
        _ = try await search("login")
        let jqls = stub.requests.compactMap { request in
            (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])?["jql"] as? String
        }
        #expect(!jqls.isEmpty)
        #expect(jqls.allSatisfy { $0.contains(#"project in ("SHOP", "PAY")"#) }, "\(jqls)")
    }
}
