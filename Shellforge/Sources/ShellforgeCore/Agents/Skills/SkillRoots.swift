// Ported from AiTerm (app/Sources/AiTermCore/Harnesses/Harness.swift and Harness+Agents.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// One place an agent keeps skills or commands, and how its CLI reads that place.
struct SkillRoot: Sendable {
    enum Kind: Sendable {
        /// Directories that hold a `SKILL.md`, each name put under `namespace` when there is one.
        /// `hidingNonInvocable` drops a skill whose frontmatter says `user-invocable: false`.
        case skills(namespace: String? = nil, hidingNonInvocable: Bool = false)
        /// Markdown commands, a subdirectory's namespaced with a colon, down to `depth`.
        case commands(namespace: String? = nil, depth: Int = SkillCatalog.maxDepth)
        /// Every installed plugin's skills and commands, under `<url>/plugins`.
        case plugins(hidingNonInvocable: Bool = false)
    }

    /// `source` is what the place's completions are offered as; a plugin's are offered as that
    /// plugin's, whatever it says.
    var kind: Kind, url: URL, source: AgentCompletion.Source

    init(_ kind: Kind, _ url: URL, _ source: AgentCompletion.Source) {
        self.kind = kind; self.url = url; self.source = source
    }
}

/// Where each preset keeps its skills and commands, in the order its CLI reads them (the first of a
/// name wins), and how it writes a skill: AiTerm's `Harness.skillRoots` and `skillSigil`, keyed by
/// `AgentDefinition.id`. An agent Shellforge has no table for — a custom one — has none.
public enum SkillRoots {
    static func roots(agentId: String, home: URL, project: URL?) -> [SkillRoot] {
        switch agentId {
        case "claude":
            // Claude Code, like Grok, keeps a `user-invocable: false` skill out of its `/` menu.
            let user = home.appendingPathComponent(".claude")
            var roots = [SkillRoot(.skills(hidingNonInvocable: true), user.appendingPathComponent("skills"), .user),
                         SkillRoot(.commands(), user.appendingPathComponent("commands"), .user),
                         SkillRoot(.plugins(hidingNonInvocable: true), user, .user)]
            if let project = project?.appendingPathComponent(".claude") {
                roots += [SkillRoot(.skills(hidingNonInvocable: true), project.appendingPathComponent("skills"), .project),
                          SkillRoot(.commands(), project.appendingPathComponent("commands"), .project)]
            }
            return roots
        case "codex":
            // Codex follows the Agent Skills standard, `.agents/skills` in the home and the repo.
            // Its own home still holds the built-ins (`skills/.system`), what its skill installer
            // adds and its (deprecated) custom prompts, which it runs as `/prompts:<name>`; none of
            // those has a project-level twin.
            let user = home.appendingPathComponent(".codex")
            var roots = [SkillRoot(.skills(), user.appendingPathComponent("skills"), .user),
                         SkillRoot(.skills(), home.appendingPathComponent(".agents/skills"), .user),
                         SkillRoot(.commands(namespace: "prompts"), user.appendingPathComponent("prompts"), .user),
                         SkillRoot(.plugins(), user, .user)]
            if let project {
                roots.append(SkillRoot(.skills(), project.appendingPathComponent(".agents/skills"), .project))
            }
            return roots
        case "grok":
            // Grok reads skills and flat commands from .grok, .agents and (Claude compatibility)
            // .claude, globally and in the project; only `commands/*.md` itself is a command
            // (08-skills.md). Its bundled skills come after the user's, which override them.
            let dots = [".grok", ".agents", ".claude"]
            func roots(in base: URL, _ source: AgentCompletion.Source) -> [SkillRoot] {
                dots.flatMap { dot in
                    [SkillRoot(.skills(hidingNonInvocable: true), base.appendingPathComponent("\(dot)/skills"), source),
                     SkillRoot(.commands(depth: 0), base.appendingPathComponent("\(dot)/commands"), source)]
                }
            }
            return roots(in: home, .user)
                + [SkillRoot(.skills(hidingNonInvocable: true), home.appendingPathComponent(".grok/bundled/skills"), .builtIn)]
                + (project.map { roots(in: $0, .project) } ?? [])
        case "pi":
            // PI runs a skill as `/skill:<name>`.
            let user = home.appendingPathComponent(".pi/agent")
            var roots = [SkillRoot(.skills(namespace: "skill"), user.appendingPathComponent("skills"), .user),
                         SkillRoot(.skills(namespace: "skill"), home.appendingPathComponent(".agents/skills"), .user),
                         SkillRoot(.commands(), user.appendingPathComponent("prompts"), .user)]
            if let project {
                roots += [SkillRoot(.skills(namespace: "skill"), project.appendingPathComponent(".pi/skills"), .project),
                          SkillRoot(.skills(namespace: "skill"), project.appendingPathComponent(".agents/skills"), .project),
                          SkillRoot(.commands(), project.appendingPathComponent(".pi/prompts"), .project)]
            }
            return roots
        default:
            return []
        }
    }

    /// What a picked skill is written with in the prompt: Codex mentions a skill as `$name` and keeps
    /// `/` for its commands; every other agent runs both from `/`.
    public static func sigil(agentId: String) -> Character { agentId == "codex" ? "$" : "/" }
}
