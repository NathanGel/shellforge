// Ported from AiTerm (app/Sources/AiTermCore/GitLab/GitLabSettings.swift), GPLv3, Laurens D'Hondt.
import Foundation

public enum GitLabSettings {
    public static func load(store: SecretStore = Keychain.shared, defaults: UserDefaults = .standard) -> GitLabConfig? {
        guard let host = defaults.string(forKey: "gitlab.host"), let url = URL(string: host),
              url.host != nil, let token = store.get("gitlab.token"), !token.isEmpty else { return nil }
        return GitLabConfig(hostURL: url, token: token)
    }

    /// The token goes in first, exactly as `JiraSettings.save` does. If the store
    /// refuses it, the host is left alone, so the saved settings never describe credentials that
    /// are not there.
    @discardableResult
    public static func save(_ cfg: GitLabConfig?, store: SecretStore = Keychain.shared, defaults: UserDefaults = .standard) -> Bool {
        guard store.set("gitlab.token", cfg?.token) else { return false }
        defaults.set(cfg?.hostURL.absoluteString, forKey: "gitlab.host")
        return true
    }
}
