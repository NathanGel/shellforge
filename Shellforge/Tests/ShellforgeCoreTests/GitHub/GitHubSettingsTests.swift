// Ported from AiTerm (app/Tests/AiTermCoreTests/GitHubSettingsTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeCore

@Suite struct GitHubSettingsTests {
    @Test func savesAndLoadsTheTokenInTheSecretStore() {
        let store = MemorySecretStore()
        #expect(GitHubSettings.load(store: store) == nil)
        #expect(GitHubSettings.save(GitHubConfig(token: "ghp_x"), store: store))
        #expect(store.get("github.token") == "ghp_x")
        #expect(GitHubSettings.load(store: store) == GitHubConfig(token: "ghp_x"))
        #expect(GitHubSettings.save(nil, store: store))
        #expect(GitHubSettings.load(store: store) == nil)
    }

    @Test func aBlankTokenIsNoConnection() {
        let store = MemorySecretStore()
        store.set("github.token", "  \n")
        #expect(GitHubSettings.load(store: store) == nil)
    }
}
