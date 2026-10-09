// Ported from AiTerm (app/Tests/AiTermCoreTests/GrokModelCatalogTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct GrokModelCatalogTests {
    /// The shape of `~/.grok/models_cache.json` from Grok 1.0.41, trimmed.
    static func cache(hiddenFast: Bool = false) -> Data {
        Data("""
        {"fetched_at":"2026-09-28T12:00:00Z","identity":"x","models":{
          "grok-4.7":{"info":{"id":"grok-4.7","name":"Grok 4.7","description":"Latest","hidden":false,
            "supports_reasoning_effort":true,"reasoning_effort":"high","reasoning_efforts":[
              {"value":"xhigh","default":false},{"value":"high","default":true},
              {"value":"medium","default":false},{"value":"low","default":false}]}},
          "grok-4.7-build-fast":{"info":{"id":"grok-4.7-build-fast","name":"Grok 4.7 Fast","hidden":\(hiddenFast),
            "supports_reasoning_effort":true,"reasoning_efforts":[{"value":"high","default":true},{"value":"low","default":false}]}},
          "grok-4.5":{"info":{"id":"grok-4.5","name":"Grok 4.5","hidden":false,
            "supports_reasoning_effort":false,"reasoning_efforts":[]}}
        }}
        """.utf8)
    }

    @Test func readsModelsInFileOrderWithAscendingEfforts() {
        let models = GrokModelCatalog.models(modelsCacheJSON: Self.cache(), configTOML: nil)
        #expect(models.map(\.id) == ["grok-4.7", "grok-4.7-build-fast", "grok-4.5"])
        #expect(models[0].label == "Grok 4.7" && models[0].detail == "Latest")
        #expect(models[0].efforts == ["low", "medium", "high", "xhigh"])
        #expect(models[0].defaultEffort == "high")
        // No reasoning support: no picker and no flag.
        #expect(models[2].efforts.isEmpty && models[2].defaultEffort == nil)
    }

    @Test func skipsHiddenModels() {
        #expect(!GrokModelCatalog.models(modelsCacheJSON: Self.cache(hiddenFast: true), configTOML: nil)
            .contains { $0.id == "grok-4.7-build-fast" })
    }

    @Test func configuredDefaultModelLeadsAndDefaultEffortApplies() {
        let toml = "[models]\ndefault = \"grok-4.7-build-fast\"\ndefault_reasoning_effort = \"low\"\n"
        let models = GrokModelCatalog.models(modelsCacheJSON: Self.cache(), configTOML: toml)
        #expect(models.first?.id == "grok-4.7-build-fast")
        #expect(models.first?.defaultEffort == "low")
        // A configured effort a model does not offer leaves that model's own default.
        let medium = GrokModelCatalog.models(modelsCacheJSON: Self.cache(),
                                             configTOML: "[models]\ndefault_reasoning_effort = \"medium\"\n")
        #expect(medium.first { $0.id == "grok-4.7-build-fast" }?.defaultEffort == "high")
    }

    @Test(arguments: [nil, Data("{}".utf8), Data("not json".utf8)])
    func missingOrMalformedCacheHasNoModels(data: Data?) {
        #expect(GrokModelCatalog.models(modelsCacheJSON: data, configTOML: nil).isEmpty)
    }
}
