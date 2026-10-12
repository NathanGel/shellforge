// Ported from AiTerm (app/Tests/AiTermCoreTests/GitLabSettingsTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct GitLabSettingsTests {
    @Test func testSaveAndLoadSplitSecretFromDefaults() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        #expect(GitLabSettings.load(store: store, defaults: defaults) == nil)
        let cfg = GitLabConfig(hostURL: URL(string: "https://git.example.net")!, token: "secret")
        #expect(GitLabSettings.save(cfg, store: store, defaults: defaults))
        #expect(GitLabSettings.load(store: store, defaults: defaults) == cfg)
        #expect(defaults.string(forKey: "gitlab.host") == "https://git.example.net")
        #expect(defaults.string(forKey: "gitlab.token") == nil)
        #expect(store.get("gitlab.token") == "secret")
        GitLabSettings.save(nil, store: store, defaults: defaults)
        #expect(GitLabSettings.load(store: store, defaults: defaults) == nil)
        #expect(store.get("gitlab.token") == nil)
    }

    /// The token goes in first, so a refused Keychain write never leaves a host behind that
    /// describes credentials which are not there.
    @Test func testRefusedSecretWriteLeavesTheHostAlone() {
        let store = RefusingSecretStore(), defaults = ScratchDefaults.make()
        let cfg = GitLabConfig(hostURL: URL(string: "https://git.example.net")!, token: "secret")
        #expect(!GitLabSettings.save(cfg, store: store, defaults: defaults))
        #expect(defaults.string(forKey: "gitlab.host") == nil)
    }
}

private final class RefusingSecretStore: SecretStore {
    func get(_ key: String) -> String? { nil }
    func set(_ key: String, _ value: String?) -> Bool { false }
}
