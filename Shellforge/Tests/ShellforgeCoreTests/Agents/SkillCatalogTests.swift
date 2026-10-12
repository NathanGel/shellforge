// Ported from AiTerm (app/Tests/AiTermCoreTests/SkillCatalogTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore

@Suite struct SkillCatalogTests {
    func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("skillcat-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func testFrontmatterDescription() {
        #expect(SkillCatalog.frontmatterValue("description", in: "---\nname: brainstorming\ndescription: Use when starting\n---\n\nbody") == "Use when starting")
        #expect(SkillCatalog.frontmatterValue("description", in: "---\ndescription: \"quoted, with: colon\"\n---\n") == "quoted, with: colon")
        #expect(SkillCatalog.frontmatterValue("description", in: "no frontmatter here") == nil)
        // A folded block scalar is what longer skill descriptions actually use.
        #expect(SkillCatalog.frontmatterValue("description", in: "---\ndescription: >-\n  first line\n  second line\nname: x\n---\n") == "first line second line")
    }

    /// Claude Code namespaces a command in a subdirectory with a colon, and that is the text the
    /// agent expects back — so the completion has to carry the same name.
    @Test func testClaudeUserCommandsAndSkills() {
        let home = tempDir()
        write("---\ndescription: Ship it\n---\n", to: home.appendingPathComponent(".claude/commands/deploy.md"))
        write("# no frontmatter\n", to: home.appendingPathComponent(".claude/commands/git/sync.md"))
        write("---\nname: brainstorming\ndescription: Explore intent\n---\n", to: home.appendingPathComponent(".claude/skills/brainstorming/SKILL.md"))

        let found = SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home)
        #expect(found.contains { $0.name == "deploy" && $0.kind == .command && $0.detail == "Ship it" })
        #expect(found.contains { $0.name == "git:sync" && $0.kind == .command })
        #expect(found.contains { $0.name == "brainstorming" && $0.kind == .skill && $0.detail == "Explore intent" })
    }

    /// Plugin skills are addressed `plugin:skill`, and the installed version is the one on disk.
    @Test func testClaudePluginSkillsAreNamespaced() {
        let home = tempDir()
        write("---\ndescription: Test first\n---\n",
              to: home.appendingPathComponent(".claude/plugins/cache/official/superpowers/6.3.0/skills/test-driven-development/SKILL.md"))
        write("---\ndescription: Review a PR\n---\n",
              to: home.appendingPathComponent(".claude/plugins/cache/official/superpowers/6.3.0/commands/review.md"))
        let found = SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home)
        #expect(found.contains { $0.name == "superpowers:test-driven-development" && $0.kind == .skill })
        #expect(found.contains { $0.name == "superpowers:review" && $0.kind == .command })
    }

    /// Version directories compare as numbers: as strings, `6.9.0` sorted after `6.10.0` and an
    /// upgrade kept offering the old version's skills.
    @Test func testTheNewestPluginVersionWinsNumerically() {
        let home = tempDir()
        for version in ["6.9.0", "6.10.0"] {
            write("---\ndescription: \(version)\n---\n",
                  to: home.appendingPathComponent(".claude/plugins/cache/official/superpowers/\(version)/skills/brainstorming/SKILL.md"))
        }
        let found = SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home)
        #expect(found.first { $0.name == "superpowers:brainstorming" }?.detail == "6.10.0")
    }

    /// Skills synced from claude.ai sit one bucket deeper; the bucket id is not part of the name.
    @Test func testClaudeSyncedSkillsDropTheBucketId() {
        let home = tempDir()
        write("---\ndescription: Make a deck\n---\n",
              to: home.appendingPathComponent(".claude/skills/synced/8ac1-bucket/pptx/SKILL.md"))
        let found = SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home)
        #expect(found.contains { $0.name == "pptx" && $0.kind == .skill })
        #expect(!found.contains { $0.name.contains("bucket") })
    }

    /// Codex keeps its built-ins under a hidden `.system` directory and its own prompts under
    /// `prompts/`; both are offered, and the leading dot never leaks into a name. A prompt runs as
    /// `/prompts:<name>`, so that is the name it carries — and typing its own name still finds it.
    @Test func testCodexPromptsAndSystemSkills() {
        let home = tempDir()
        write("Do the thing\n", to: home.appendingPathComponent(".codex/prompts/handoff.md"))
        write("---\ndescription: Generate an image\n---\n", to: home.appendingPathComponent(".codex/skills/.system/imagegen/SKILL.md"))
        write("---\ndescription: Mine\n---\n", to: home.appendingPathComponent(".codex/skills/my-skill/SKILL.md"))
        let found = SkillCatalog.discover(agentId: "codex", projectPath: nil, home: home)
        #expect(found.contains { $0.name == "prompts:handoff" && $0.kind == .command })
        #expect(SkillCatalog.matches(found, query: "hand").map(\.name) == ["prompts:handoff"])
        #expect(found.contains { $0.name == "imagegen" && $0.kind == .skill })
        #expect(found.contains { $0.name == "my-skill" && $0.kind == .skill })
        #expect(!found.contains { $0.name.hasPrefix(".") })
    }

    /// Codex follows the Agent Skills standard: `.agents/skills` in the home and in the project,
    /// next to the built-ins its own home still keeps. It has no project-level `.codex` skills or
    /// prompts, so those are not offered.
    @Test func testCodexReadsTheAgentSkillsStandard() {
        let home = tempDir(), project = tempDir()
        let skill = "---\ndescription: d\n---\n"
        write(skill, to: home.appendingPathComponent(".agents/skills/user-std/SKILL.md"))
        write(skill, to: project.appendingPathComponent(".agents/skills/repo-std/SKILL.md"))
        write(skill, to: home.appendingPathComponent(".codex/skills/.system/imagegen/SKILL.md"))
        write(skill, to: project.appendingPathComponent(".codex/skills/not-codex/SKILL.md"))
        write(skill, to: project.appendingPathComponent(".codex/prompts/not-codex-either.md"))
        let found = SkillCatalog.discover(agentId: "codex", projectPath: project.path, home: home)
        #expect(found.map(\.name) == ["imagegen", "repo-std", "user-std"])
        #expect(found.first { $0.name == "repo-std" }?.source == .project)
        #expect(found.first { $0.name == "user-std" }?.source == .user)
    }

    /// A skill shared between agents is usually a symlink in each agent's folder. Every CLI
    /// follows it, so the popup must too — and offer it once when two roots point at it.
    @Test func testSymlinkedSkillsAndCommandsAreFollowed() throws {
        let home = tempDir(), store = tempDir()
        write("---\ndescription: Shared\n---\n", to: store.appendingPathComponent("shared/SKILL.md"))
        write("---\ndescription: Linked\n---\n", to: store.appendingPathComponent("linked.md"))
        write("---\ndescription: Nested\n---\n", to: store.appendingPathComponent("ops/rollout.md"))
        let fm = FileManager.default
        for dot in [".claude", ".agents"] {
            try fm.createDirectory(at: home.appendingPathComponent("\(dot)/skills"), withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: home.appendingPathComponent("\(dot)/skills/shared"), withDestinationURL: store.appendingPathComponent("shared"))
        }
        try fm.createDirectory(at: home.appendingPathComponent(".claude/commands"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: home.appendingPathComponent(".claude/commands/linked.md"), withDestinationURL: store.appendingPathComponent("linked.md"))
        try fm.createSymbolicLink(at: home.appendingPathComponent(".claude/commands/ops"), withDestinationURL: store.appendingPathComponent("ops"))

        let claude = SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home)
        #expect(claude.map(\.name) == ["linked", "ops:rollout", "shared"])
        #expect(claude.first { $0.name == "shared" }?.detail == "Shared")
        for agent in ["codex", "grok"] {
            #expect(SkillCatalog.discover(agentId: agent, projectPath: nil, home: home).filter { $0.name == "shared" }.count == 1, "\(agent)")
        }
    }

    /// A whole skills root can be a link too — `~/.agents/skills -> ../.claude/skills` is a
    /// common way to give every agent the same set — and it names each skill once.
    @Test func testASymlinkedSkillsRootIsRead() throws {
        let home = tempDir()
        write("---\ndescription: d\n---\n", to: home.appendingPathComponent(".claude/skills/mine/SKILL.md"))
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".agents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.appendingPathComponent(".agents/skills").path, withDestinationPath: "../.claude/skills")
        #expect(SkillCatalog.discover(agentId: "codex", projectPath: nil, home: home).map(\.name) == ["mine"])
        #expect(SkillCatalog.discover(agentId: "grok", projectPath: nil, home: home).map(\.name) == ["mine"])
        #expect(SkillCatalog.discover(agentId: "pi", projectPath: nil, home: home).map(\.name) == ["skill:mine"])
    }

    /// A symlink that points back up the tree must not send the walk round forever.
    @Test func testASymlinkLoopEnds() throws {
        let home = tempDir()
        write("---\ndescription: d\n---\n", to: home.appendingPathComponent(".claude/skills/real/SKILL.md"))
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".claude/skills/real/loop"),
                                                   withDestinationURL: home.appendingPathComponent(".claude/skills"))
        let found = SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home)
        #expect(found.map(\.name) == ["real"])
    }

    /// Claude Code parks a removed skill under `skills/.trash/<id>/`; it is gone, so it is not
    /// offered. Hidden directories are skipped in general, bar Codex's built-in `.system`.
    @Test func testTrashedSkillsAreNotOffered() {
        let home = tempDir()
        write("---\ndescription: d\n---\n", to: home.appendingPathComponent(".claude/skills/.trash/1790-abc/deleted/SKILL.md"))
        write("---\ndescription: d\n---\n", to: home.appendingPathComponent(".claude/skills/kept/SKILL.md"))
        #expect(SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home).map(\.name) == ["kept"])
        #expect(SkillCatalog.discover(agentId: "grok", projectPath: nil, home: home).map(\.name) == ["kept"])
    }

    /// A project's own `.claude` directory is scanned too, and its entries are marked as the
    /// project's so the popup can say where a command comes from.
    @Test func testProjectScopedCommands() {
        let home = tempDir(), project = tempDir()
        write("---\ndescription: Project only\n---\n", to: project.appendingPathComponent(".claude/commands/release.md"))
        let found = SkillCatalog.discover(agentId: "claude", projectPath: project.path, home: home)
        let release = found.first { $0.name == "release" }
        #expect(release != nil)
        #expect(release?.source == .project)
    }

    @Test func testPiSkillsAndPromptsUsePiPathsAndSlashSyntax() {
        let home = tempDir(), project = tempDir()
        write("---\nname: global-skill\n---\n", to: home.appendingPathComponent(".pi/agent/skills/global-skill/SKILL.md"))
        write("---\nname: shared-skill\n---\n", to: home.appendingPathComponent(".agents/skills/shared-skill/SKILL.md"))
        write("---\nname: project-skill\n---\n", to: project.appendingPathComponent(".agents/skills/project-skill/SKILL.md"))
        write("Prompt\n", to: home.appendingPathComponent(".pi/agent/prompts/handoff.md"))
        write("Prompt\n", to: project.appendingPathComponent(".pi/prompts/review.md"))

        let found = SkillCatalog.discover(agentId: "pi", projectPath: project.path, home: home)
        #expect(found.map(\.name).contains("skill:global-skill"))
        #expect(found.map(\.name).contains("skill:shared-skill"))
        #expect(found.map(\.name).contains("skill:project-skill"))
        #expect(found.map(\.name).contains("handoff"))
        #expect(found.map(\.name).contains("review"))
        #expect(SkillCatalog.trigger(in: "/skill:g", caret: 8)?.query == "skill:g")
    }

    @Test func grokReadsGrokAgentsAndClaudeRoots() {
        let home = tempDir(), project = tempDir()
        let skill = "---\ndescription: d\n---\n"
        write(skill, to: home.appendingPathComponent(".grok/skills/alpha/SKILL.md"))
        write(skill, to: home.appendingPathComponent(".agents/skills/beta/SKILL.md"))
        write(skill, to: home.appendingPathComponent(".claude/skills/gamma/SKILL.md"))
        write(skill, to: home.appendingPathComponent(".grok/commands/deploy.md"))
        write(skill, to: project.appendingPathComponent(".grok/skills/delta/SKILL.md"))
        write(skill, to: project.appendingPathComponent(".claude/commands/ship.md"))
        let names = SkillCatalog.discover(agentId: "grok", projectPath: project.path, home: home).map(\.name)
        #expect(names == ["alpha", "beta", "delta", "deploy", "gamma", "ship"])
    }

    /// Grok's bundled skills are offered, below a user skill of the same name; its commands are
    /// flat `commands/*.md` only; and a `user-invocable: false` skill is not a slash command.
    @Test func grokOffersBundledSkillsFlatCommandsAndOnlyInvocableSkills() throws {
        let home = tempDir()
        write("---\ndescription: bundled\n---\n", to: home.appendingPathComponent(".grok/bundled/skills/design/SKILL.md"))
        write("---\ndescription: bundled\n---\n", to: home.appendingPathComponent(".grok/bundled/skills/review/SKILL.md"))
        write("---\ndescription: mine\n---\n", to: home.appendingPathComponent(".grok/skills/review/SKILL.md"))
        write("---\nuser-invocable: false\n---\n", to: home.appendingPathComponent(".grok/skills/background/SKILL.md"))
        write("---\ndescription: d\n---\n", to: home.appendingPathComponent(".claude/commands/sub/nested.md"))
        write("---\ndescription: d\n---\n", to: home.appendingPathComponent(".claude/commands/flat.md"))
        let found = SkillCatalog.discover(agentId: "grok", projectPath: nil, home: home)
        #expect(found.map(\.name) == ["design", "flat", "review"])
        let review = try #require(found.first { $0.name == "review" })
        #expect(review.detail == "mine" && review.source == .user)
        #expect(found.first { $0.name == "design" }?.source == .builtIn)
    }

    /// Claude Code honours `user-invocable: false` too; Codex documents no such key.
    @Test func onlyClaudeAndGrokHideNonInvocableSkills() {
        let home = tempDir()
        write("---\nuser-invocable: False\n---\n", to: home.appendingPathComponent(".claude/skills/hidden/SKILL.md"))
        write("---\nuser-invocable: false\n---\n", to: home.appendingPathComponent(".codex/skills/shown/SKILL.md"))
        #expect(SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home).isEmpty)
        #expect(SkillCatalog.discover(agentId: "codex", projectPath: nil, home: home).map(\.name) == ["shown"])
    }

    @Test func testNoDuplicatesAndStableOrder() {
        let home = tempDir()
        write("---\ndescription: One\n---\n", to: home.appendingPathComponent(".claude/skills/dup/SKILL.md"))
        write("---\ndescription: Two\n---\n", to: home.appendingPathComponent(".claude/commands/dup.md"))
        let found = SkillCatalog.discover(agentId: "claude", projectPath: nil, home: home)
        #expect(found.filter { $0.name == "dup" }.count == 1, "a name is offered once, whichever kind found it first")
        #expect(found == found.sorted { $0.name < $1.name })
    }

    @Test func testMatching() {
        let items = [
            AgentCompletion(name: "brainstorming", kind: .skill, detail: "Explore intent", source: .user),
            AgentCompletion(name: "superpowers:test-driven-development", kind: .skill, detail: nil, source: .plugin("superpowers")),
            AgentCompletion(name: "review", kind: .command, detail: "Review the diff", source: .user),
        ]
        #expect(SkillCatalog.matches(items, query: "").count == 3, "an empty query offers everything")
        #expect(SkillCatalog.matches(items, query: "bra").map(\.name) == ["brainstorming"])
        #expect(SkillCatalog.matches(items, query: "BRA").map(\.name) == ["brainstorming"], "matching ignores case")
        // A prefix match outranks a match in the middle of the name.
        #expect(SkillCatalog.matches(items, query: "test").map(\.name) == ["superpowers:test-driven-development"])
        #expect(SkillCatalog.matches(items, query: "tdd").isEmpty)
        #expect(SkillCatalog.matches(items, query: "review").map(\.name) == ["review"])
    }

    /// What the popup needs from the text being typed: the token under the caret, only when it is
    /// the start of a word and starts with `/` — the one trigger, for every agent.
    @Test func testTriggerDetection() {
        // A slash at the start of a line or after whitespace.
        #expect(SkillCatalog.trigger(in: "/bra", caret: 4)?.query == "bra")
        #expect(SkillCatalog.trigger(in: "do it /rev", caret: 10)?.query == "rev")
        #expect(SkillCatalog.trigger(in: "http://x", caret: 8) == nil, "a slash inside a word is not a command")
        #expect(SkillCatalog.trigger(in: "/bra more", caret: 9) == nil, "the caret has left the token")
        // Shellforge: mid-word offers nothing (AiTerm offered "b"); see aCaretMidWordOpensNoPopup.
        #expect(SkillCatalog.trigger(in: "/bra", caret: 2) == nil, "a pick mid-word would leave the rest of the word")
        // The token's range is what gets replaced when a completion is picked.
        let t = SkillCatalog.trigger(in: "hi /rev", caret: 7)
        #expect(t?.range == 3..<7)
        // `$` opens nothing, Codex included: a price or `$HOME` in a prompt stays plain text.
        #expect(SkillCatalog.trigger(in: "$imag", caret: 5) == nil)
    }

    /// A picked item is written as its agent runs it: Codex mentions a skill with `$` and keeps `/`
    /// for its commands; every other agent runs both from `/`.
    @Test func aPickedItemIsWrittenAsItsAgentRunsIt() {
        let skill = AgentCompletion(name: "imagegen", kind: .skill, detail: nil, source: .builtIn)
        let prompt = AgentCompletion(name: "prompts:draft", kind: .command, detail: nil, source: .user)
        #expect(SkillCatalog.invocation(of: skill, agentId: "codex") == "$imagegen")
        #expect(SkillCatalog.invocation(of: prompt, agentId: "codex") == "/prompts:draft")
        for agent in ["claude", "grok", "pi"] {
            #expect(SkillCatalog.invocation(of: skill, agentId: agent) == "/imagegen")
            #expect(SkillCatalog.invocation(of: prompt, agentId: agent) == "/prompts:draft")
        }
    }

    /// Every sheet opening and every agent switch walked the skill trees and read every `SKILL.md`.
    /// A discovery now stands while nothing it looked at has changed: a skill rewritten in place
    /// with its size and date kept still answers from the cache, and any change a `stat` sees — a
    /// new date, a new skill, a project directory appearing — is read again.
    @Test func aDiscoveryStandsUntilSomethingItLookedAtChanges() throws {
        let home = tempDir(), project = tempDir()
        defer { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: project) }
        let manifest = home.appendingPathComponent(".claude/skills/alpha/SKILL.md")
        let dated = Date(timeIntervalSince1970: 1_800_000_000)
        write("---\ndescription: First\n---\n", to: manifest)
        try FileManager.default.setAttributes([.modificationDate: dated], ofItemAtPath: manifest.path)
        func found() -> [String] {
            SkillCatalog.discover(agentId: "claude", projectPath: project.path, home: home).map { "\($0.name)=\($0.detail ?? "")" }
        }
        #expect(found() == ["alpha=First"])

        let handle = try FileHandle(forWritingTo: manifest)
        try handle.write(contentsOf: Data("---\ndescription: Again\n---\n".utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: dated], ofItemAtPath: manifest.path)
        #expect(found() == ["alpha=First"], "nothing a stat sees has changed")

        try FileManager.default.setAttributes([.modificationDate: dated.addingTimeInterval(1)], ofItemAtPath: manifest.path)
        #expect(found() == ["alpha=Again"])

        write("---\ndescription: Second\n---\n", to: home.appendingPathComponent(".claude/skills/beta/SKILL.md"))
        #expect(found() == ["alpha=Again", "beta=Second"])

        write("---\ndescription: Here\n---\n", to: project.appendingPathComponent(".claude/commands/local.md"))
        #expect(found() == ["alpha=Again", "beta=Second", "local=Here"])
    }

    /// Only the block at the top of a file is read, however long the body after it.
    @Test func frontmatterIsReadFromTheTopOfALongFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("SKILL.md")
        let body = String(repeating: "Some — body text.\n", count: 20_000)
        write("---\nname: long\ndescription: >-\n  folded\n  text\nuser-invocable: false\n---\n" + body + "description: not this\n", to: file)
        #expect(SkillCatalog.frontmatter(of: file) == ["name": "long", "description": "folded text", "user-invocable": "false"])
        write("no frontmatter\n---\ndescription: x\n---\n", to: file)
        #expect(SkillCatalog.frontmatter(of: file).isEmpty)
        #expect(SkillCatalog.frontmatter(of: dir.appendingPathComponent("missing.md")).isEmpty)
    }

    /// The block is read in chunks, and the first chunk can end inside a character of the body:
    /// that half character must not cost the frontmatter it follows.
    @Test func aCharacterSplitByTheChunkBoundaryKeepsTheFrontmatter() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("SKILL.md")
        let head = "---\nname: split\ndescription: Kept\nuser-invocable: false\n---\n"
        let padding = String(repeating: "a", count: 8191 - head.utf8.count)
        let text = head + padding + "—" + "tail\n"
        #expect(Array(text.utf8)[8191] == 0xE2, "the dash's three bytes straddle byte 8192")
        write(text, to: file)
        #expect(SkillCatalog.frontmatter(of: file) == ["name": "split", "description": "Kept", "user-invocable": "false"])
    }
}
