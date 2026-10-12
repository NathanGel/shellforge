// Ported from AiTerm (app/Sources/AiTermCore/Jira/JiraSettings.swift), GPLv3, Laurens D'Hondt.
import Foundation

public enum JiraSettings {
    public static func load(store: SecretStore = Keychain.shared, defaults: UserDefaults = .standard) -> JiraConfig? {
        guard let site = defaults.string(forKey: "jira.site"), let url = URL(string: site), let email = defaults.string(forKey: "jira.email"), let token = store.get("jira.token"), !token.isEmpty else { return nil }
        return JiraConfig(siteURL: url, email: email, token: token)
    }

    /// The token goes in first. If the store refuses it, the site and the email are
    /// left alone, so the saved settings never describe credentials that are not there.
    @discardableResult
    public static func save(_ cfg: JiraConfig?, store: SecretStore = Keychain.shared, defaults: UserDefaults = .standard) -> Bool {
        guard store.set("jira.token", cfg?.token) else { return false }
        defaults.set(cfg?.siteURL.absoluteString, forKey: "jira.site")
        defaults.set(cfg?.email, forKey: "jira.email")
        return true
    }
}
