import Foundation

/// Versions before 2026-11 kept the Jira site and email, the GitLab host, Backpack's network and
/// Settings › Agents' default models in the bundle-id domain (`.standard`), which a dev
/// build shares with the installed app and which a custom preferences folder, `make reset-suite` and
/// an export all miss. They live in the app's own suite now. Once per suite, at launch, each one the
/// suite does not have yet is copied in; the old domain is left as it was, so the installed app's
/// older version still finds its own.
///
/// Backpack's crash marker is not copied: launch recovery reads it where it was
/// (`BackpackSettings.legacyEngaged`).
public enum SettingsMigration {
    /// Set once the copy ran: this Mac's bookkeeping, not a setting.
    public static let doneKey = "NoSyncShellforgeSettingsMovedToSuite"

    /// The keys copied, besides every `ModelSettings` key.
    static let keys = ["jira.site", "jira.email", "gitlab.host", BackpackSettings.Key.network]

    /// Copies what `suite` lacks from `old`, once. Nothing is copied when they are the same domain.
    public static func run(from old: UserDefaults, into suite: UserDefaults) {
        guard !suite.bool(forKey: doneKey) else { return }
        defer { suite.set(true, forKey: doneKey) }
        guard old !== suite else { return }
        let models = old.dictionaryRepresentation().keys.filter { $0.hasPrefix(ModelSettings.keyPrefix) }
        for key in keys + models.sorted() where suite.object(forKey: key) == nil {
            guard let value = old.object(forKey: key) else { continue }
            suite.set(value, forKey: key)
        }
    }
}
