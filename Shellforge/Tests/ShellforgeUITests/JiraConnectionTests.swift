// Ported from AiTerm (app/Tests/AiTermTests/IntegrationSettingsModelTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Settings' Jira card, off the view: what Save stores and refuses, and when the card's connection
/// is tested. AiTerm's cases, on the one card Shellforge has until GitLab and GitHub arrive with
/// reviews; the cases that need two cards wait for them. Keychain writes go to a
/// `MemorySecretStore`; the tester is a stand-in.
@MainActor
@Suite(.serialized) struct JiraConnectionTests {
    static let site = URL(string: "https://example.atlassian.net")!
    static let jira = JiraConfig(siteURL: site, email: "me@example.com", token: "jira-token")

    /// The configs the card was tested with; the tester runs off the main actor.
    final class Testers: Sendable {
        private let calls = Locked<[JiraConfig]>([])
        var jiraCalls: [JiraConfig] { calls.withLock { $0 } }
        func tested(_ config: JiraConfig) { calls.withLock { $0.append(config) } }
    }

    private func model(jira: JiraConfig? = nil, store: SecretStore = MemorySecretStore(),
                       defaults: UserDefaults = ScratchDefaults.make(), testers: Testers = Testers(),
                       retestDelay: Duration = .milliseconds(20),
                       jiraAnswer: @escaping @Sendable () async throws -> String = { "Jira Person" }) -> IntegrationSettingsModel {
        IntegrationSettingsModel(jira: jira, store: store, defaults: defaults, retestDelay: retestDelay,
                                 testJira: { testers.tested($0); return try await jiraAnswer() })
    }

    @Test func blankFieldsSaveNothing() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let m = model(store: store, defaults: defaults)
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
    }

    @Test func saveStoresTheTypedServiceBehindTheSecretStore() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let m = model(store: store, defaults: defaults)
        m.jira.fields = JiraFields(Self.jira)
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == Self.jira)
        #expect(defaults.string(forKey: "jira.token") == nil, "the token is the Keychain's alone")
    }

    @Test func anInvalidURLIsRefusedAndNothingIsStored() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let m = model(store: store, defaults: defaults)
        m.jira.fields.site = "jira"
        m.jira.fields.email = "me@example.com"
        m.jira.fields.token = "jira-token"
        #expect(m.save() == "Enter a valid Jira site URL")
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
    }

    @Test func aRefusingKeychainIsSaid() {
        let m = model(store: RefusingSecretStore())
        m.jira.fields = JiraFields(Self.jira)
        #expect(m.save() == "Couldn’t save the API token to the Keychain")
    }

    @Test func openingTestsAConfiguredService() async {
        let testers = Testers()
        let unset = model(testers: testers)
        unset.testConfigured()
        #expect(unset.jira.status == SettingsStatus(.idle, "Not set up"))
        #expect(testers.jiraCalls.isEmpty)
        let m = model(jira: Self.jira, testers: testers)
        m.testConfigured()
        await eventually { m.jira.test == .connected("Jira Person") }
        #expect(m.jira.status == SettingsStatus(.ready, "Connected as Jira Person"))
        #expect(testers.jiraCalls == [Self.jira])
    }

    @Test func anEditClearsTheAnswerAndRetestsOnceTypingPauses() async {
        let testers = Testers()
        let m = model(testers: testers)
        m.jira.fields.site = "https://example.atlassian.net"
        m.jira.fields.email = "me@example.com"
        m.jira.fields.token = "jira"
        m.jira.fields.token = "jira-token"
        #expect(m.jira.test == nil)
        await eventually { m.jira.test == .connected("Jira Person") }
        #expect(testers.jiraCalls == [Self.jira])
        m.jira.fields.token = "jira-token-2"
        #expect(m.jira.test == nil, "the answer was for the fields before the edit")
    }

    @Test func aFailedTestSaysWhy() async {
        let m = model(jira: Self.jira, jiraAnswer: { throw JiraError.unauthorized })
        m.testConfigured()
        await eventually { m.jira.test != nil && m.jira.test != .running }
        #expect(m.jira.test == .failed(JiraError.unauthorized.localizedDescription))
    }

    @Test func disconnectIsOfferedOverSavedCredentialsOnly() {
        #expect(!model().jira.canDisconnect)
        let saved = model(jira: Self.jira)
        #expect(saved.jira.canDisconnect)
        saved.jira.disconnect()
        #expect(!saved.jira.canDisconnect)
    }

    @Test func saveRemovesADisconnectedService() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        _ = JiraSettings.save(Self.jira, store: store, defaults: defaults)
        let m = model(jira: Self.jira, store: store, defaults: defaults)
        m.jira.disconnect()
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
    }

    @Test func disconnectWithoutSaveKeepsEverything() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        _ = JiraSettings.save(Self.jira, store: store, defaults: defaults)
        let m = model(jira: Self.jira, store: store, defaults: defaults)
        m.jira.disconnect()
        #expect(JiraSettings.load(store: store, defaults: defaults) == Self.jira)
    }

    @Test func credentialsTypedAfterDisconnectAreSaved() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        _ = JiraSettings.save(Self.jira, store: store, defaults: defaults)
        let m = model(jira: Self.jira, store: store, defaults: defaults)
        m.jira.disconnect()
        let other = JiraConfig(siteURL: Self.site, email: "other@example.com", token: "t2")
        m.jira.fields = JiraFields(other)
        #expect(m.save() == nil)
        #expect(JiraSettings.load(store: store, defaults: defaults) == other)
    }

    @Test func aRefusingKeychainIsSaidOnRemovalToo() {
        let m = model(jira: Self.jira, store: RefusingSecretStore())
        m.jira.disconnect()
        #expect(m.save() == "Couldn’t remove the API token from the Keychain")
    }
}

/// A Keychain that refuses every write, as one locked or denied does.
final class RefusingSecretStore: SecretStore {
    func get(_ key: String) -> String? { nil }
    func set(_ key: String, _ value: String?) -> Bool { false }
}
