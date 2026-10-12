// Ported from AiTerm (app/Tests/AiTermTests/IntegrationSettingsModelTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The Integrations tab's logic, off the view: what Save stores and refuses, and when each card's
/// connection is tested. Keychain writes go to a `MemorySecretStore`; the testers are stand-ins.
@MainActor
@Suite(.serialized) struct IntegrationSettingsModelTests {
    static let site = URL(string: "https://example.atlassian.net")!
    static let jira = JiraConfig(siteURL: site, email: "me@example.com", token: "jira-token")
    static let gitLab = GitLabConfig(hostURL: URL(string: "https://git.example.net")!, token: "gl-token")
    static let gitHub = GitHubConfig(token: "gh-token")

    /// The configs each service was tested with. The testers run off the main actor, so the
    /// record is kept behind a lock.
    final class Testers: Sendable {
        private let calls = Locked<(jira: [JiraConfig], gitLab: [GitLabConfig], gitHub: [GitHubConfig])>(([], [], []))
        var jiraCalls: [JiraConfig] { calls.withLock { $0.jira } }
        var gitLabCalls: [GitLabConfig] { calls.withLock { $0.gitLab } }
        var gitHubCalls: [GitHubConfig] { calls.withLock { $0.gitHub } }
        func tested(_ config: JiraConfig) { calls.withLock { $0.jira.append(config) } }
        func tested(_ config: GitLabConfig) { calls.withLock { $0.gitLab.append(config) } }
        func tested(_ config: GitHubConfig) { calls.withLock { $0.gitHub.append(config) } }
    }

    private func model(jira: JiraConfig? = nil, gitLab: GitLabConfig? = nil, gitHub: GitHubConfig? = nil,
                       store: SecretStore = MemorySecretStore(),
                       defaults: UserDefaults = ScratchDefaults.make(), testers: Testers = Testers(),
                       record: ServiceTestRecord = ServiceTestRecord(), retestDelay: Duration = .milliseconds(20),
                       jiraAnswer: @escaping @Sendable () async throws -> String = { "Jira Person" }) -> IntegrationSettingsModel {
        IntegrationSettingsModel(jira: jira, gitLab: gitLab, gitHub: gitHub, store: store, defaults: defaults, record: record,
                                 retestDelay: retestDelay,
                                 testJira: { testers.tested($0); return try await jiraAnswer() },
                                 testGitLab: { testers.tested($0); return "GitLab Person" },
                                 testGitHub: { testers.tested($0); return "octocat" })
    }

    @Test func gitHubSavesAndDisconnectsItsToken() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let m = model(store: store, defaults: defaults)
        m.gitHub.fields = GitHubFields(Self.gitHub)
        #expect(m.save() == nil)
        #expect(GitHubSettings.load(store: store) == Self.gitHub)

        let reopened = model(gitHub: Self.gitHub, store: store, defaults: defaults)
        #expect(reopened.gitHub.canDisconnect)
        reopened.gitHub.disconnect()
        #expect(reopened.save() == nil)
        #expect(GitHubSettings.load(store: store) == nil)
    }

    @Test func aSavedGitHubTokenIsTestedOnOpeningAndAfterTypingPauses() async {
        let testers = Testers()
        let m = model(gitHub: Self.gitHub, testers: testers)
        m.testConfigured()
        await eventually { m.gitHub.test == .connected("octocat") }
        #expect(testers.gitHubCalls == [Self.gitHub])
        m.gitHub.fields.token = "gh-other"
        await eventually { testers.gitHubCalls.count == 2 }
        #expect(testers.gitHubCalls.last == GitHubConfig(token: "gh-other"))
    }

    @Test func aBlankGitHubCardSavesNothing() {
        let store = MemorySecretStore()
        let m = model(store: store)
        m.gitHub.fields.token = "   "
        #expect(m.save() == nil)
        #expect(GitHubSettings.load(store: store) == nil)
    }

    @Test func blankFieldsSaveNothing() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let m = model(store: store, defaults: defaults)
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        #expect(GitLabSettings.load(store: store, defaults: defaults) == nil)
    }

    @Test func saveStoresEachTypedServiceBehindTheSecretStore() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let m = model(store: store, defaults: defaults)
        m.jira.fields = JiraFields(Self.jira)
        m.gitLab.fields = GitLabFields(Self.gitLab)
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == Self.jira)
        #expect(GitLabSettings.load(store: store, defaults: defaults) == Self.gitLab)
    }

    /// A URL without a host is refused before anything is stored — neither service is half-saved.
    @Test func anInvalidURLIsRefusedAndNothingIsStored() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let m = model(store: store, defaults: defaults)
        m.jira.fields.site = "not a url"
        m.jira.fields.email = "me@example.com"
        #expect(m.save() == "Enter a valid Jira site URL")
        m.jira.fields = JiraFields(nil)
        m.gitLab.fields.token = "gl-token"
        m.gitLab.fields.host = "gitlab"
        #expect(m.save() == "Enter a valid GitLab host URL")
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        #expect(GitLabSettings.load(store: store, defaults: defaults) == nil)
    }

    @Test func aRefusingKeychainIsSaid() {
        let m = model(store: RefusingSecretStore())
        m.gitLab.fields = GitLabFields(Self.gitLab)
        #expect(m.save() == "Couldn’t save the GitLab token to the Keychain")
        m.jira.fields = JiraFields(Self.jira)
        #expect(m.save() == "Couldn’t save the API token to the Keychain")
    }

    /// Opening tests only the services with enough filled in, and each answer lands on its card.
    @Test func openingTestsEachConfiguredServiceOnItsOwnCard() async {
        let testers = Testers()
        let m = model(jira: Self.jira, testers: testers)
        #expect(m.jira.status == SettingsStatus(.idle, "Not tested yet"))
        #expect(m.gitLab.status == SettingsStatus(.idle, "Not set up"))
        m.testConfigured()
        await eventually { m.jira.test != .running }
        #expect(m.jira.status == SettingsStatus(.ready, "Connected as Jira Person"))
        #expect(m.gitLab.test == nil)
        #expect(testers.jiraCalls == [Self.jira])
        #expect(testers.gitLabCalls.isEmpty)
    }

    /// An edit clears the card's answer at once and, once typing pauses, tests the new fields —
    /// once, however many keystrokes came before the pause.
    @Test func anEditClearsTheAnswerAndRetestsOnceTypingPauses() async {
        let testers = Testers()
        let m = model(testers: testers)
        m.gitLab.fields.host = "https://git.example.net"
        m.gitLab.fields.token = "gl"
        m.gitLab.fields.token = "gl-token"
        #expect(m.gitLab.test == nil)
        await eventually { m.gitLab.test == .connected("GitLab Person") }
        #expect(m.gitLab.test == .connected("GitLab Person"))
        #expect(testers.gitLabCalls == [Self.gitLab])

        m.gitLab.fields.token = "gl-token-2"
        #expect(m.gitLab.test == nil, "the answer was for the fields before the edit")
    }

    /// A test still running when the fields change answers for fields no longer shown: dropped.
    @Test func anAnswerForEditedFieldsIsDropped() async {
        let gate = Gate()
        // A retest far off, so the only answer that could land is the stale one.
        let m = model(jira: Self.jira, retestDelay: .seconds(60), jiraAnswer: { await gate.wait(); return "Stale" })
        m.jira.runTest()
        #expect(m.jira.test == .running)
        m.jira.fields.email = "other@example.com"
        await gate.open()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(m.jira.test == nil)
    }

    /// Disconnect is offered only over credentials saved earlier, and once pressed it is gone.
    @Test func disconnectIsOfferedOverSavedCredentialsOnly() {
        let m = model(jira: Self.jira)
        #expect(m.jira.canDisconnect)
        #expect(!m.gitLab.canDisconnect)
        m.jira.disconnect()
        #expect(m.jira.fields == JiraFields(nil))
        #expect(m.jira.status == SettingsStatus(.idle, "Not set up"))
        #expect(!m.jira.canDisconnect)
    }

    /// Save removes the saved site or host and the Keychain token of each disconnected service.
    @Test func saveRemovesADisconnectedService() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        JiraSettings.save(Self.jira, store: store, defaults: defaults)
        GitLabSettings.save(Self.gitLab, store: store, defaults: defaults)
        let m = model(jira: Self.jira, gitLab: Self.gitLab, store: store, defaults: defaults)
        m.jira.disconnect()
        m.gitLab.disconnect()
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        #expect(GitLabSettings.load(store: store, defaults: defaults) == nil)
        #expect(store.get("jira.token") == nil)
        #expect(store.get("gitlab.token") == nil)
        #expect(defaults.string(forKey: "jira.site") == nil)
        #expect(defaults.string(forKey: "gitlab.host") == nil)
    }

    /// Nothing is removed until Save: a sheet cancelled after Disconnect leaves everything saved.
    @Test func disconnectWithoutSaveKeepsEverything() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        JiraSettings.save(Self.jira, store: store, defaults: defaults)
        let m = model(jira: Self.jira, store: store, defaults: defaults)
        m.jira.disconnect()
        #expect(JiraSettings.load(store: store, defaults: defaults) == Self.jira)
    }

    /// New credentials typed in after Disconnect are what Save stores.
    @Test func credentialsTypedAfterDisconnectAreSaved() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        JiraSettings.save(Self.jira, store: store, defaults: defaults)
        let m = model(jira: Self.jira, store: store, defaults: defaults)
        m.jira.disconnect()
        let other = JiraConfig(siteURL: URL(string: "https://other.atlassian.net")!, email: "you@example.com", token: "t2")
        m.jira.fields = JiraFields(other)
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == other)
    }

    @Test func aRefusingKeychainIsSaidOnRemovalToo() {
        let m = model(gitLab: Self.gitLab, store: RefusingSecretStore())
        m.gitLab.disconnect()
        #expect(m.save() == "Couldn’t remove the GitLab token from the Keychain")
    }

    /// A card that cannot save stops the whole Save before anything is written: a Disconnect on
    /// Jira, and a new GitLab host mistyped, leave Jira's credentials where they were, so Cancel
    /// keeps everything.
    @Test func aFailingLaterCardLeavesEarlierCredentialsUntouched() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        JiraSettings.save(Self.jira, store: store, defaults: defaults)
        let m = model(jira: Self.jira, store: store, defaults: defaults)
        m.jira.disconnect()
        m.gitLab.fields.host = "gitlab"
        m.gitLab.fields.token = "gl-token"
        #expect(m.save() == "Enter a valid GitLab host URL")
        #expect(JiraSettings.load(store: store, defaults: defaults) == Self.jira)
        #expect(GitLabSettings.load(store: store, defaults: defaults) == nil)

        let other = JiraConfig(siteURL: URL(string: "https://other.atlassian.net")!, email: "you@example.com", token: "t2")
        m.jira.fields = JiraFields(other)
        #expect(m.save() == "Enter a valid GitLab host URL")
        #expect(JiraSettings.load(store: store, defaults: defaults) == Self.jira)
    }

    /// Once the failing card is fixed, the same Save writes everything it held back.
    @Test func fixingTheFailingCardLetsTheWholeSaveThrough() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        JiraSettings.save(Self.jira, store: store, defaults: defaults)
        let m = model(jira: Self.jira, store: store, defaults: defaults)
        m.jira.disconnect()
        m.gitLab.fields.host = "gitlab"
        m.gitLab.fields.token = "gl-token"
        #expect(m.save() != nil)
        m.gitLab.fields = GitLabFields(Self.gitLab)
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        #expect(GitLabSettings.load(store: store, defaults: defaults) == Self.gitLab)
    }

    /// A Keychain that refuses a later card's write puts back what Save had already written, and
    /// the model's own record of what is saved stays as it was.
    @Test func aRefusedWritePutsBackTheEarlierWritesOfThisSave() {
        let memory = MemorySecretStore(), defaults = ScratchDefaults.make()
        JiraSettings.save(Self.jira, store: memory, defaults: defaults)
        let store = RefusingKeySecretStore(wrapping: memory, refusing: "gitlab.token")
        let record = ServiceTestRecord()
        let m = model(jira: Self.jira, store: store, defaults: defaults, record: record)
        m.jira.disconnect()
        m.gitLab.fields = GitLabFields(Self.gitLab)
        m.gitHub.fields = GitHubFields(Self.gitHub)
        #expect(m.save() == "Couldn’t save the GitLab token to the Keychain")
        #expect(JiraSettings.load(store: memory, defaults: defaults) == Self.jira)
        #expect(GitLabSettings.load(store: memory, defaults: defaults) == nil)
        #expect(GitHubSettings.load(store: memory) == nil)

        // A second Save, with the Keychain willing, still sees Jira as saved and stores the rest.
        store.refused = nil
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: memory, defaults: defaults) == nil)
        #expect(GitLabSettings.load(store: memory, defaults: defaults) == Self.gitLab)
        #expect(GitHubSettings.load(store: memory) == Self.gitHub)
    }

    /// An earlier card's write that did land is undone when a later one is refused.
    @Test func anEarlierNewConfigIsUndoneWhenALaterWriteIsRefused() {
        let memory = MemorySecretStore(), defaults = ScratchDefaults.make()
        let store = RefusingKeySecretStore(wrapping: memory, refusing: "github.token")
        let m = model(store: store, defaults: defaults)
        m.jira.fields = JiraFields(Self.jira)
        m.gitLab.fields = GitLabFields(Self.gitLab)
        m.gitHub.fields = GitHubFields(Self.gitHub)
        #expect(m.save() == "Couldn’t save the GitHub token to the Keychain")
        #expect(JiraSettings.load(store: memory, defaults: defaults) == nil)
        #expect(GitLabSettings.load(store: memory, defaults: defaults) == nil)
        #expect(memory.get("jira.token") == nil)
        #expect(defaults.string(forKey: "jira.site") == nil)
    }

    /// A replaced config is put back as it was, not removed: Jira saved as A and typed in as B, then
    /// GitLab refused, leaves A in the Keychain and the defaults.
    @Test func aReplacedConfigIsPutBackWhenALaterWriteIsRefused() {
        let memory = MemorySecretStore(), defaults = ScratchDefaults.make()
        JiraSettings.save(Self.jira, store: memory, defaults: defaults)
        let store = RefusingKeySecretStore(wrapping: memory, refusing: "gitlab.token")
        let m = model(jira: Self.jira, store: store, defaults: defaults)
        let other = JiraConfig(siteURL: URL(string: "https://other.atlassian.net")!, email: "you@example.com", token: "t2")
        m.jira.fields = JiraFields(other)
        m.gitLab.fields = GitLabFields(Self.gitLab)
        #expect(m.save() == "Couldn’t save the GitLab token to the Keychain")
        #expect(JiraSettings.load(store: memory, defaults: defaults) == Self.jira)
        #expect(memory.get("jira.token") == Self.jira.token)
        #expect(defaults.string(forKey: "jira.site") == Self.site.absoluteString)
    }

    /// A Save that fails — a card that cannot save, or a write the Keychain refuses — leaves what
    /// Settings opens on next as it was: the record of each saved service's last test.
    @Test func aFailedSaveLeavesTheTestRecordUntouched() {
        let memory = MemorySecretStore(), defaults = ScratchDefaults.make()
        JiraSettings.save(Self.jira, store: memory, defaults: defaults)
        let store = RefusingKeySecretStore(wrapping: memory, refusing: "gitlab.token")
        let record = ServiceTestRecord()
        record.jiraFailed = true
        let m = model(jira: Self.jira, store: store, defaults: defaults, record: record)
        m.jira.disconnect()
        m.gitLab.fields.host = "gitlab"
        m.gitLab.fields.token = "gl-token"
        #expect(m.save() == "Enter a valid GitLab host URL")
        #expect(record.jiraFailed && !record.gitLabFailed)

        m.gitLab.fields = GitLabFields(Self.gitLab)
        #expect(m.save() == "Couldn’t save the GitLab token to the Keychain")
        #expect(record.jiraFailed && !record.gitLabFailed, "a removed Jira would have cleared its flag")
    }

    /// Putting back an earlier write can itself be refused; the footer then says which service
    /// was left changed rather than only what stopped the Save.
    @Test func anUndoTheKeychainRefusesIsSaid() {
        let memory = MemorySecretStore(), defaults = ScratchDefaults.make()
        // Jira's token lands; every write after it — GitLab's, then Jira's undo — is refused.
        let store = CountingSecretStore(wrapping: memory, allowing: 1)
        let m = model(store: store, defaults: defaults)
        m.jira.fields = JiraFields(Self.jira)
        m.gitLab.fields = GitLabFields(Self.gitLab)
        #expect(m.save() == "Couldn’t save the GitLab token to the Keychain and couldn’t put back the Jira settings")

        // Two earlier writes left changed are both named.
        let both = model(store: CountingSecretStore(wrapping: MemorySecretStore(), allowing: 2), defaults: ScratchDefaults.make())
        both.jira.fields = JiraFields(Self.jira)
        both.gitLab.fields = GitLabFields(Self.gitLab)
        both.gitHub.fields = GitHubFields(Self.gitHub)
        #expect(both.save() == "Couldn’t save the GitHub token to the Keychain and couldn’t put back the Jira and GitLab settings")
    }

    /// A saved service's test answer is remembered for the next opening; a test of fields not yet
    /// saved is not, until Save stores them.
    @Test func aSavedServicesLastTestIsRemembered() async {
        let record = ServiceTestRecord()
        let failing = model(jira: Self.jira, record: record, jiraAnswer: { throw URLError(.userAuthenticationRequired) })
        failing.testConfigured()
        await eventually { failing.jira.test != .running }
        #expect(record.jiraFailed)
        #expect(record.anyFailed)

        let passing = model(jira: Self.jira, record: record)
        passing.testConfigured()
        await eventually { passing.jira.test != .running }
        #expect(!record.jiraFailed)

        let unsaved = model(record: record, jiraAnswer: { throw URLError(.userAuthenticationRequired) })
        unsaved.jira.fields = JiraFields(Self.jira)
        unsaved.jira.runTest()
        await eventually { unsaved.jira.test != .running }
        #expect(!record.jiraFailed, "those fields were never saved")
        #expect(unsaved.save() == nil)
        #expect(record.jiraFailed, "saved now, and their last test failed")

        unsaved.jira.disconnect()
        #expect(unsaved.save() == nil)
        #expect(!record.jiraFailed, "a removed service has no last test")
    }

    @Test func aURLWithoutAHostFailsItsTestAtOnce() {
        let m = model()
        m.jira.fields.site = "nope"
        m.jira.runTest()
        #expect(m.jira.test == .failed("Enter a valid Jira site URL"))
    }

    /// A token goes only over https: the app lets plain http reach local-network hosts, so an
    /// `http://gitlab` or an IP address would carry it unencrypted. A URL with a user or password in
    /// it is refused too, before it could be stored.
    @Test(arguments: ["http://gitlab", "http://10.0.0.5", "https://me:secret@git.example.net", "ftp://git.example.net"])
    func aGitLabHostThatIsNotPlainHTTPSIsRefusedAndNothingIsStoredOrTested(host: String) async {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make(), testers = Testers()
        let m = model(store: store, defaults: defaults, testers: testers)
        m.gitLab.fields.host = host
        m.gitLab.fields.token = "gl-token"
        #expect(m.save() == "Enter a valid GitLab host URL")
        #expect(GitLabSettings.load(store: store, defaults: defaults) == nil)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(testers.gitLabCalls.isEmpty, "the token was sent to \(host)")
    }

    @Test func aJiraSiteOverPlainHTTPIsRefused() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let m = model(store: store, defaults: defaults)
        m.jira.fields = JiraFields(Self.jira)
        m.jira.fields.site = "http://jira.local"
        #expect(m.save() == "Enter a valid Jira site URL")
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
    }

    /// A client's refusal reaches the card in the client's own words.
    @Test func aFailedTestSaysWhy() async {
        let m = model(jira: Self.jira, jiraAnswer: { throw JiraError.unauthorized })
        m.testConfigured()
        await eventually { m.jira.test != nil && m.jira.test != .running }
        #expect(m.jira.test == .failed(JiraError.unauthorized.localizedDescription))
    }
}

private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
}

private final class RefusingSecretStore: SecretStore {
    func get(_ key: String) -> String? { nil }
    func set(_ key: String, _ value: String?) -> Bool { false }
}

/// A store that refuses writes to one key and passes the rest to a real one.
private final class RefusingKeySecretStore: SecretStore {
    private let wrapped: SecretStore
    var refused: String?
    init(wrapping wrapped: SecretStore, refusing key: String) { self.wrapped = wrapped; refused = key }
    func get(_ key: String) -> String? { wrapped.get(key) }
    func set(_ key: String, _ value: String?) -> Bool { key == refused ? false : wrapped.set(key, value) }
}

/// A store that takes the first `allowing` writes and refuses every one after.
private final class CountingSecretStore: SecretStore {
    private let wrapped: SecretStore
    private var remaining: Int
    init(wrapping wrapped: SecretStore, allowing count: Int) { self.wrapped = wrapped; remaining = count }
    func get(_ key: String) -> String? { wrapped.get(key) }
    func set(_ key: String, _ value: String?) -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return wrapped.set(key, value)
    }
}
