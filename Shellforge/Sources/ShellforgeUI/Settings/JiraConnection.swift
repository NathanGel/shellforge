// Ported from AiTerm (app/Sources/AiTerm/IntegrationSettingsModel.swift and Views/SettingsView.swift), GPLv3, Laurens D'Hondt.
import Combine
import Foundation
import ShellforgeCore
import SwiftUI

/// A service's Settings fields as typed, and what they add up to.
protocol ServiceFields: Equatable {
    associatedtype Config: Equatable & Sendable
    /// The connection these fields describe, or `nil` while the URL has no host.
    var config: Config? { get }
    /// Enough to test: a URL with a host and every credential filled in.
    var isConfigured: Bool { get }
    /// Anything typed at all, the untouched `https://` aside. Blank fields save nothing; anything
    /// else must make a valid connection to save.
    var hasInput: Bool { get }
    /// The fields for `config`; for `nil`, as a card with nothing saved opens.
    init(_ config: Config?)
}

/// What the URL field starts on, so the person types only the host.
private let urlPrefix = "https://"

private func typed(_ values: [String]) -> Bool {
    values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct JiraFields: ServiceFields {
    var site: String, email: String, token: String

    init(_ config: JiraConfig?) {
        site = config?.siteURL.absoluteString ?? urlPrefix
        email = config?.email ?? ""
        token = config?.token ?? ""
    }

    var config: JiraConfig? { URL(string: site).flatMap { $0.host == nil ? nil : JiraConfig(siteURL: $0, email: email, token: token) } }
    var isConfigured: Bool { config != nil && !email.isEmpty && !token.isEmpty }
    var hasInput: Bool { typed([site == urlPrefix ? "" : site, email, token]) }
}

/// Whether each saved service's last connection test failed, which the tab Settings opens on reads.
/// Held for the app's run: every opening tests again anyway, so this only has to outlive one
/// presentation of the sheet until the next.
@MainActor
final class ServiceTestRecord {
    static let shared = ServiceTestRecord()
    var jiraFailed = false
    var anyFailed: Bool { jiraFailed }
}

extension ConnectionTest {
    var failed: Bool { if case .failed = self { true } else { false } }
}

/// One service's card: its fields and the answer of its last connection test. The test runs when
/// Settings opens and again once the fields stop changing; there is no Test button.
@MainActor
final class ServiceConnection<Fields: ServiceFields>: ObservableObject {
    /// An edit clears the card's answer and, once typing pauses for `retestDelay`, tests again.
    @Published var fields: Fields {
        didSet { if fields != oldValue { edited() } }
    }
    @Published private(set) var test: ConnectionTest?
    /// Disconnect was pressed: Save removes the saved credentials unless new ones are typed in.
    @Published private(set) var disconnecting = false
    /// Settings opened on credentials saved earlier — what Disconnect removes.
    let isSaved: Bool
    /// What the card says when the URL has no host.
    let invalidURL: String
    /// Hears every answer a test lands, with the fields it was for.
    var answered: ((Fields.Config, ConnectionTest) -> Void)?
    private let connect: @Sendable (Fields.Config) async throws -> String
    private let retestDelay: Duration
    private var retest: Task<Void, Never>?

    init(fields: Fields, isSaved: Bool, invalidURL: String, retestDelay: Duration,
         connect: @escaping @Sendable (Fields.Config) async throws -> String) {
        self.fields = fields; self.isSaved = isSaved; self.invalidURL = invalidURL
        self.retestDelay = retestDelay; self.connect = connect
    }

    var status: SettingsStatus { IntegrationCardPresentation.status(configured: fields.isConfigured, test: test) }

    /// Offered while the card holds credentials saved earlier and Disconnect has not been pressed.
    var canDisconnect: Bool { isSaved && !disconnecting }

    /// Empties the card and marks the service for removal. Nothing is removed until Save, so
    /// Cancel keeps everything.
    func disconnect() {
        fields = Fields(nil)
        disconnecting = true
    }

    func runTest() {
        guard let config = fields.config else { test = .failed(invalidURL); return }
        test = .running
        Task {
            let outcome: ConnectionTest
            do { outcome = .connected(try await connect(config)) }
            catch { outcome = .failed(error.localizedDescription) }
            // An edit during the test cleared the card; the answer is for fields no longer shown.
            if test == .running, fields.config == config {
                test = outcome
                answered?(config, outcome)
            }
        }
    }

    /// The opening test has already set an answer by the time a retest could wake, so a card is
    /// never tested twice for the same fields. Held weakly: Settings closed meanwhile tests nothing.
    private func edited() {
        test = nil
        retest?.cancel()
        retest = Task { [weak self, retestDelay] in
            try? await Task.sleep(for: retestDelay)
            guard !Task.isCancelled, let self, self.test == nil, self.fields.isConfigured else { return }
            self.runTest()
        }
    }
}

/// Owns Settings' Jira card: its fields as typed, its connection test, and the Keychain writes Save
/// makes. AiTerm's `IntegrationSettingsModel` with its one card Shellforge has so far; GitLab and
/// GitHub come back with reviews. The card observes its connection for itself.
@MainActor
final class IntegrationSettingsModel {
    let jira: ServiceConnection<JiraFields>
    private let store: SecretStore
    private let defaults: UserDefaults
    private let record: ServiceTestRecord
    /// What is saved now: only a test of it counts as the saved service's last test.
    private var savedJira: JiraConfig?

    /// `store` and `defaults` are where Save writes; the tester is the real client unless a test
    /// stands in for it.
    init(jira: JiraConfig?, store: SecretStore = Keychain.shared, defaults: UserDefaults = .standard,
         record: ServiceTestRecord = ServiceTestRecord(), retestDelay: Duration = .seconds(1),
         testJira: @escaping @Sendable (JiraConfig) async throws -> String = { try await JiraClient(config: $0).testConnection() }) {
        self.jira = ServiceConnection(fields: JiraFields(jira), isSaved: jira != nil, invalidURL: "Enter a valid Jira site URL",
                                      retestDelay: retestDelay, connect: testJira)
        self.store = store; self.defaults = defaults; self.record = record
        savedJira = jira
        self.jira.answered = { [weak self] config, outcome in
            guard let self, config == self.savedJira else { return }
            self.record.jiraFailed = outcome.failed
        }
    }

    /// A result is only true for the moment it was taken, so every opening tests the saved service
    /// again rather than showing a remembered answer.
    func testConfigured() {
        if jira.fields.isConfigured { jira.runTest() }
    }

    /// Stores what is typed, or removes what Disconnect left blank; blank fields store nothing. `nil`
    /// when it was done, else what stopped it, for the panel's footer.
    func save() -> String? {
        let card = jira
        if card.fields.hasInput {
            guard let config = card.fields.config else { return card.invalidURL }
            guard JiraSettings.save(config, store: store, defaults: defaults) else { return "Couldn’t save the API token to the Keychain" }
            savedJira = config
            record.jiraFailed = card.test?.failed == true
            return nil
        }
        guard card.disconnecting else { return nil }
        guard JiraSettings.save(nil, store: store, defaults: defaults) else { return "Couldn’t remove the API token from the Keychain" }
        savedJira = nil
        record.jiraFailed = false
        return nil
    }
}

enum ConnectionTest: Equatable {
    case running
    case connected(String)
    case failed(String)
}

enum IntegrationCardPresentation {
    static func status(configured: Bool, test: ConnectionTest?) -> SettingsStatus {
        switch test {
        case .running: SettingsStatus(.idle, "Testing…")
        case .connected(let name): SettingsStatus(.ready, "Connected as \(name)")
        case .failed(let explanation): SettingsStatus(.attention, explanation)
        case nil: SettingsStatus(.idle, configured ? "Not tested yet" : "Not set up")
        }
    }
}
