import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ModelCatalogueTests {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A launcher whose PATH holds only `bin`: no test reaches the developer's own CLIs.
    private func launcher(bin: URL) -> CommandLauncher {
        CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": bin.path, "HOME": bin.deletingLastPathComponent().path], source: .fallback("test")) })
    }

    private func script(_ name: String, in bin: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let file = bin.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }

    @Test func aFreshClaudeOffersTheAliases() throws {
        let home = try home()
        let models = try ModelCatalogue(home: home, launcher: launcher(bin: home.appendingPathComponent("bin"))).models(for: AgentPresets.claude)
        #expect(models.map(\.id) == ["opus", "sonnet", "fable", "haiku"])
    }

    @Test func codexWithNoCacheOffersItsConfiguredModel() throws {
        let home = try home()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try "model = \"gpt-5.7\"\n".write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        let models = try ModelCatalogue(home: home, launcher: launcher(bin: home.appendingPathComponent("bin"))).models(for: AgentPresets.codex)
        #expect(models.map(\.id) == ["gpt-5.7"])
    }

    @Test func piIsListedByItsCLI() throws {
        let home = try home(), bin = home.appendingPathComponent("bin")
        try script("pi", in: bin, """
        echo 'provider  model   context  max-out  thinking  images'
        echo 'anthropic claude-x 200K    64K      yes       yes'
        """)
        let models = try ModelCatalogue(home: home, launcher: launcher(bin: bin)).models(for: AgentPresets.pi)
        #expect(models.map(\.id) == ["anthropic/claude-x"])
    }

    @Test func piNotInstalledSaysItCannotBeLaunched() throws {
        let home = try home()
        #expect(throws: PiModelCatalogError.unavailable) {
            try ModelCatalogue(home: home, launcher: launcher(bin: home.appendingPathComponent("bin"))).models(for: AgentPresets.pi)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aSilentPiTimesOut() throws {
        let home = try home(), bin = home.appendingPathComponent("bin")
        // By path: the launcher's PATH holds only `bin`, so a bare `sleep` would fail at once instead of hanging.
        try script("pi", in: bin, "exec /bin/sleep 30\n")
        let started = Date()
        let error = #expect(throws: PiModelCatalogError.self) {
            try ModelCatalogue(home: home, launcher: launcher(bin: bin)).models(for: AgentPresets.pi)
        }
        #expect(error == .timedOut)
        #expect(error?.localizedDescription == "PI didn’t answer within 5 seconds.")
        let waited = Date().timeIntervalSince(started)
        #expect(waited > 4 && waited < 10, "PI was given \(waited) s, not its five")
    }

    @Test func anAgentWithAFixedListOffersIt() throws {
        let home = try home()
        let agent = AgentDefinition(id: "local", name: "Local", command: "local", models: .fixed(["a", "b"]),
                                    reasoningLevels: ["low", "high"], defaultReasoning: "high")
        let models = try ModelCatalogue(home: home, launcher: launcher(bin: home.appendingPathComponent("bin"))).models(for: agent)
        #expect(models == [AgentModel(id: "a", label: "a", detail: nil, efforts: ["low", "high"], defaultEffort: "high"),
                           AgentModel(id: "b", label: "b", detail: nil, efforts: ["low", "high"], defaultEffort: "high")])
    }

    @Test func theRememberedModelWinsElseTheFirst() {
        let a = AgentModel(id: "a", label: "A", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
        let b = AgentModel(id: "b", label: "B", detail: nil, efforts: [], defaultEffort: nil)
        #expect(ModelPreference.resolve(catalog: [a, b], remembered: "b") == ModelPreference(model: "b", reasoning: nil))
        #expect(ModelPreference.resolve(catalog: [a, b], remembered: "gone") == ModelPreference(model: "a", reasoning: "high"))
        #expect(ModelPreference.resolve(catalog: [], remembered: "a") == ModelPreference(model: "", reasoning: nil))
    }
}
