// Ported from AiTerm (app/Sources/AiTermCore/GitHub/GitHubSettings.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// GitHub is github.com only, so the token is the whole connection: nothing goes in defaults.
public enum GitHubSettings {
    public static func load(store: SecretStore = Keychain.shared) -> GitHubConfig? {
        guard let token = store.get("github.token")?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return nil }
        return GitHubConfig(token: token)
    }

    @discardableResult
    public static func save(_ cfg: GitHubConfig?, store: SecretStore = Keychain.shared) -> Bool {
        store.set("github.token", cfg?.token)
    }
}
