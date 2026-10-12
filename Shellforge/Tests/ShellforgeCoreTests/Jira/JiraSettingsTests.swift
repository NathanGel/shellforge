// Ported from AiTerm (app/Tests/AiTermCoreTests/JiraSettingsTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct JiraSettingsTests {
    @Test func testSaveAndLoadSplitSecretFromDefaults() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        let cfg = JiraConfig(siteURL: URL(string: "http://alice:password@x.atlassian.net:80/")!,
                             email: "me@x.com", token: "secret")
        JiraSettings.save(cfg, store: store, defaults: defaults)
        #expect(JiraSettings.load(store: store, defaults: defaults) == cfg)
        #expect(defaults.string(forKey: "jira.site") == "http://x.atlassian.net")
        #expect(defaults.string(forKey: "jira.token") == nil)
        #expect(store.get("jira.token") == "secret")
        JiraSettings.save(nil, store: store, defaults: defaults)
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        #expect(store.get("jira.token") == nil)
    }
}
