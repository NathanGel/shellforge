import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

/// The settings earlier versions kept in the bundle-id domain, copied into the app's suite.
@Suite struct SettingsMigrationTests {
    /// Each key the suite lacks is copied, once; what the suite has wins; the old domain keeps all of
    /// it; and a later change in the old domain (the installed app's older version) is not copied.
    @Test func theOldValuesMoveOnce() {
        let old = MemoryDefaults.make(), suite = MemoryDefaults.make()
        old.set("https://example.atlassian.net", forKey: "jira.site")
        old.set("dev@example.com", forKey: "jira.email")
        old.set("https://gitlab.example.com", forKey: "gitlab.host")
        old.set("Example Phone", forKey: "backpack.network")
        old.set(["model": "opus", "reasoning": "high"], forKey: "ShellforgeModelDefaults.claude")
        old.set(true, forKey: "backpack.engaged")
        old.set("unrelated", forKey: "SomethingElse")
        suite.set("https://gitlab.suite.example.com", forKey: "gitlab.host")

        SettingsMigration.run(from: old, into: suite)

        #expect(suite.string(forKey: "jira.site") == "https://example.atlassian.net")
        #expect(suite.string(forKey: "jira.email") == "dev@example.com")
        #expect(suite.string(forKey: "gitlab.host") == "https://gitlab.suite.example.com", "the suite's own value wins")
        #expect(BackpackSettings(defaults: suite).network == "Example Phone")
        #expect(ModelSettings.load(for: "claude", defaults: suite) == ModelPreference(model: "opus", reasoning: "high"))
        #expect(suite.object(forKey: "backpack.engaged") == nil, "the crash marker is recovered where it is, not copied")
        #expect(suite.object(forKey: BackpackSettings.Key.engaged) == nil)
        #expect(suite.object(forKey: "SomethingElse") == nil)
        #expect(suite.bool(forKey: SettingsMigration.doneKey))
        #expect(old.string(forKey: "jira.site") == "https://example.atlassian.net", "the old domain is left as it was")
        #expect(old.bool(forKey: "backpack.engaged"))

        old.set("https://other.atlassian.net", forKey: "jira.site")
        suite.removeObject(forKey: "jira.email")
        SettingsMigration.run(from: old, into: suite)
        #expect(suite.string(forKey: "jira.site") == "https://example.atlassian.net", "copied once")
        #expect(suite.object(forKey: "jira.email") == nil, "a value removed since stays removed")
    }
}
