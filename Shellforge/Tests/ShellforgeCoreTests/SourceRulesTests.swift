import Foundation
import Testing

/// Rules about the package's own source that a review would miss.
@Suite struct SourceRulesTests {
    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// A child started anywhere else would get the app's launchd environment, and the "uv not found"
    /// bug would be back. Every command goes through `CommandLauncher`, which ends in `ChildProcess`.
    @Test func onlyChildProcessCreatesAProcess() throws {
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        // `Process`, not `ChildProcess`: the name alone, followed by a call.
        let spawn = try Regex(#"(^|[^A-Za-z_])(Process\(\)|Process\.run\(|NSTask\b|posix_spawn)"#).anchorsMatchLineEndings()
        let offenders = try files.filter { $0.lastPathComponent != "ChildProcess.swift" }.filter { file in
            try String(contentsOf: file, encoding: .utf8).contains(spawn)
        }
        #expect(offenders.isEmpty, "Start children through CommandLauncher: \(offenders.map(\.lastPathComponent))")
    }

    /// Every package line reaches the host's debug log through `LogSink`, so nothing makes an os
    /// `Logger` of its own: `PackageLogger` (and the design system's `DesignLog`) are the only ones.
    @Test func everyLoggerGoesThroughTheSink() throws {
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let offenders = try files.filter { !["PackageLog.swift", "DesignLog.swift"].contains($0.lastPathComponent) }.filter { file in
            try String(contentsOf: file, encoding: .utf8).contains("Logger(subsystem:")
        }
        #expect(offenders.isEmpty, "Log through PackageLogger: \(offenders.map(\.lastPathComponent))")
    }

    /// Shellforge always runs under a suite of its own (`-suite`), and `UserDefaults.standard` is the
    /// bundle-id domain a dev build shares with the installed app: settings saved there leak between
    /// them and miss the suite's plist. So nothing in the package defaults to it, and the host names
    /// it only for what earlier versions left there: the migration's source and Backpack's old marker.
    @Test func settingsUseTheAppsSuite() throws {
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let standard = try Regex(#"UserDefaults\.standard|UserDefaults\??\s*=\s*\.standard|defaults:\s*\.standard"#)
        let offenders = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains(standard) }
        #expect(offenders.isEmpty, "Take the app's suite from the host: \(offenders.map(\.lastPathComponent))")

        // Every Shellforge file of the host, in any folder: Swift that names Shellforge, and the
        // Objective-C files named for it.
        let host = sources.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("sources")
        let hostFiles = try #require(FileManager.default.enumerator(at: host, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { file in
                switch file.pathExtension {
                case "swift": (try? String(contentsOf: file, encoding: .utf8))?.contains("Shellforge") == true
                case "m", "h": file.lastPathComponent.contains("Shellforge")
                default: false
                }
            }
        #expect(hostFiles.contains { $0.lastPathComponent == "iTermShellforgeSidebar.swift" })
        let hostLines = try hostFiles.flatMap { try String(contentsOf: $0, encoding: .utf8).split(separator: "\n").map(String.init) }
        // The two the host may name: Backpack's old crash marker and the migration's source.
        let allowed = ["legacy: UserDefaults.standard", "SettingsMigration.run(from: UserDefaults.standard"]
        let stray = try hostLines.filter { line in
            (try line.contains(Regex(#"\.standard\b"#)) && line.contains("efaults") || line.contains("standardUserDefaults"))
                && !allowed.contains { line.contains($0) }
        }
        #expect(stray.isEmpty, "Pass iTermUserDefaults.userDefaults(): \(stray)")
    }

    /// With a custom settings folder, loading it replaces every syncable key in the suite, so the
    /// settings copied in from the old domain must come after it, or they are wiped the moment
    /// they arrive and the once-only copy never runs again.
    @Test func theSettingsMoveInAfterTheSettingsFolderIsLoaded() throws {
        let delegate = sources.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sources/AppKit/iTermApplicationDelegate.m")
        let text = try String(contentsOf: delegate, encoding: .utf8)
        let load = try #require(text.range(of: "[iTermPreferences initializeUserDefaults]"))
        let migrations = try #require(text.range(of: "[iTermUserDefaults performMigrations]"))
        let move = try #require(text.range(of: "[iTermShellforgeSidebar moveSettingsIntoSuite]"))
        #expect(load.upperBound < move.lowerBound && migrations.upperBound < move.lowerBound)
        #expect(text.components(separatedBy: "moveSettingsIntoSuite").count == 2, "called once")
        #expect(!text.contains("migrateKeys:@[@\"jira"), "a plain write, so the folder's save carries it")
    }

    /// No package default reaches the person's Keychain: the host hands in `Keychain.shared`, and a
    /// test that forgets a store gets a compile error, not a prompt or a real secret.
    @Test func noDefaultReachesTheRealKeychain() throws {
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let offenders = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains(Regex(#"=\s*(Keychain\.shared|\{\s*\w+Settings\.load\(\))"#)) }
        #expect(offenders.isEmpty, "Take the store from the caller: \(offenders.map(\.lastPathComponent))")
        let tests = sources.deletingLastPathComponent().appendingPathComponent("Tests")
        let testFiles = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SourceRulesTests.swift" }
        let reaching = try testFiles.filter { try String(contentsOf: $0, encoding: .utf8).contains("Keychain.shared") }
        #expect(reaching.isEmpty, "Use MemorySecretStore: \(reaching.map(\.lastPathComponent))")
    }

    /// No test reaches the network, loopback included: a refused port behaves differently behind a
    /// sandbox, a proxy or a service that happens to listen there. Every session a test makes goes
    /// through a stub protocol; a plain one would dial. (Hook URLs written into config text are
    /// not dialled, and stay.)
    @Test func noTestDialsARealHost() throws {
        let tests = sources.deletingLastPathComponent().appendingPathComponent("Tests")
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SourceRulesTests.swift" }
        let dial = try Regex(#"URLSession\.shared|URLSession\(configuration: \.(ephemeral|default)\)"#)
        let offenders = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains(dial) }
        #expect(offenders.isEmpty, "Stub the transport instead: \(offenders.map(\.lastPathComponent))")
    }

    /// No test reads the user's environment: a launcher built without its own `resolve` runs the
    /// user's login shell, with their rc files. Every sidebar reads the environment as it starts.
    @Test func noTestRunsARealLoginShell() throws {
        let tests = sources.deletingLastPathComponent().appendingPathComponent("Tests")
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" && $0.lastPathComponent != "SourceRulesTests.swift" }
        let offenders = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("CommandLauncher()") }
        #expect(offenders.isEmpty, "Give the launcher a scripted resolve: \(offenders.map(\.lastPathComponent))")
    }

    /// Code taken from AiTerm is GPLv3 and keeps its author: every file that says it was ported
    /// names AiTerm and the file it came from, the licence and Laurens D'Hondt.
    @Test func everyPortedFileCreditsAiTerm() throws {
        let root = sources.deletingLastPathComponent()
        let files = ["Sources", "Tests"].flatMap { folder in
            (FileManager.default.enumerator(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        }
        // The header comment, however many lines it runs to.
        let wrong = try files.filter { file in
            let header = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .prefix { $0.hasPrefix("//") }.joined(separator: " ")
            guard header.contains("Ported from") else { return false }
            return !(header.contains("Ported from AiTerm (") && header.contains("GPLv3, Laurens D'Hondt."))
        }
        #expect(wrong.isEmpty, "Credit AiTerm as the other ported files do: \(wrong.map(\.lastPathComponent))")
    }

    /// Shellforge's own code is GPLv3 (it carries AiTerm's), so the licence's text ships with it; and
    /// artwork taken under another licence — a logo "MIT-licensed" in its comment — has its notice.
    @Test func theLicencesTheCodeNamesShipWithIt() throws {
        let root = sources.deletingLastPathComponent()
        let licence = try String(contentsOf: root.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(licence.contains("GNU GENERAL PUBLIC LICENSE") && licence.contains("Version 3, 29 June 2007"))
        let notices = try String(contentsOf: root.appendingPathComponent("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        let logos = try String(contentsOf: sources.appendingPathComponent("ShellforgeDesign/Logos.swift"), encoding: .utf8)
        for source in ["LobeHub"] where logos.contains(source) {
            #expect(notices.contains(source) && notices.contains("MIT License"), "\(source)'s MIT notice is missing")
        }
    }

    /// Every secret lives in one Keychain item, read once per process by `Keychain.shared`. A second
    /// instance anywhere in the app would read the item again, and ask the person again after an update.
    @Test func theAppBuildsNoSecondKeychain() throws {
        let root = sources.deletingLastPathComponent()
        let folders = [sources, root.deletingLastPathComponent().appendingPathComponent("sources")]
        let files = folders.flatMap { folder in
            (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        }
        #expect(files.contains { $0.lastPathComponent == "iTermShellforgeSidebar.swift" })
        let second = try Regex(#"(^|[^A-Za-z_.])Keychain\((service:|\))"#).anchorsMatchLineEndings()
        let offenders = try files.filter { $0.lastPathComponent != "SecretStore.swift" }.filter { file in
            let text = try String(contentsOf: file, encoding: .utf8)
            return text.contains("Keychain(") && text.contains(second)
        }
        #expect(offenders.isEmpty, "Use Keychain.shared: \(offenders.map(\.lastPathComponent))")
    }
}
