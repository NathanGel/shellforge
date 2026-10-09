// Ported from AiTerm (app/Tests/AiTermCoreTests/BackpackSettingsTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

@Suite struct BackpackSettingsTests {
    @Test func defaultsToNoNetworkAndNotEngaged() {
        let settings = BackpackSettings(defaults: ScratchDefaults.make())
        #expect(settings.network == nil)
        #expect(!settings.engaged)
    }

    @Test func roundTripsThroughTheSameDefaults() {
        let defaults = ScratchDefaults.make()
        let settings = BackpackSettings(defaults: defaults)
        settings.network = "Laurens D’Hondt - iPhone"
        settings.engaged = true
        let again = BackpackSettings(defaults: defaults)
        #expect(again.network == "Laurens D’Hondt - iPhone")
        #expect(again.engaged)
    }

    /// An empty name reads as none.
    @Test func anEmptyNetworkReadsAsNone() {
        let defaults = ScratchDefaults.make()
        defaults.set("", forKey: "backpack.network")
        let settings = BackpackSettings(defaults: defaults)
        #expect(settings.network == nil)
    }

    /// Without defaults the values live in memory: what Settings previews and tests get.
    @Test func withoutDefaultsTheValuesStayInMemory() {
        let settings = BackpackSettings(defaults: nil)
        settings.network = "Phone"
        #expect(settings.network == "Phone")
    }

    /// The password lives in the secret store, never in defaults; an empty one clears it.
    @Test func thePasswordRoundTripsThroughTheSecretStoreOnly() {
        let defaults = ScratchDefaults.make(), secrets = MemorySecretStore()
        let settings = BackpackSettings(defaults: defaults, secrets: secrets)
        #expect(settings.password == nil)
        settings.password = "hunter2"
        #expect(BackpackSettings(defaults: defaults, secrets: secrets).password == "hunter2")
        #expect(secrets.get("backpack.password") == "hunter2")
        #expect(defaults.dictionaryRepresentation().values.compactMap { $0 as? String }.allSatisfy { $0 != "hunter2" })
        settings.password = ""
        #expect(settings.password == nil)
        #expect(secrets.get("backpack.password") == nil)
    }

    @Test func theCutoffIsNoLongerAPreference() {
        #expect(BackpackSettings.cutoff == 10)
    }
}
