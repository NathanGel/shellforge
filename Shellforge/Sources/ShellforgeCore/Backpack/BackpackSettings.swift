// Ported from AiTerm (app/Sources/AiTermCore/Backpack/BackpackSettings.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Backpack Mode's preferences and its crash marker. In `UserDefaults` when given one — the app's
/// own suite — as `InterfaceSettings` is; in memory without, for previews and an app built without
/// the live ports. The network's password goes to `secrets` — the Keychain in the app — never to
/// defaults. `legacy` is where versions before 2026-11 kept the crash marker (the bundle-id domain,
/// which a dev build shares with the installed app): only launch recovery reads it.
///
/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe but not marked `Sendable`; the
/// memory copy and every `secrets` call are taken under `lock`. (A `Mutex` cannot hold them: neither
/// `Any` nor a `SecretStore` is `Sendable`.)
public final class BackpackSettings: @unchecked Sendable {
    /// The battery level, in percent, at or below which the mode turns itself off on battery power.
    /// Fixed (spec 2026-10-05): nobody tunes it, so nothing shows it.
    public static let cutoff = 10

    public enum Key {
        public static let network = "backpack.network"
        /// The crash marker: this Mac's state, not a setting, so `NoSync`.
        public static let engaged = "NoSyncShellforgeBackpackEngaged"
        /// The crash marker as versions before 2026-11 named it, in the bundle-id domain.
        public static let legacyEngaged = "backpack.engaged"
        static let password = "backpack.password"
    }

    private let defaults: UserDefaults?
    private let legacy: UserDefaults?
    private let secrets: any SecretStore
    private let lock = Locked(())
    private var memory: [String: Any] = [:]

    public init(defaults: UserDefaults?, legacy: UserDefaults? = nil, secrets: any SecretStore = MemorySecretStore()) {
        self.defaults = defaults
        self.legacy = legacy
        self.secrets = secrets
    }

    /// The chosen network's password. macOS will not hand an iPhone hotspot's saved password to
    /// another app, so the person types it once. An empty one reads as none.
    public var password: String? {
        get { lock.withLock { _ in secrets.get(Key.password) }.flatMap { $0.isEmpty ? nil : $0 } }
        set { setPassword(newValue) }
    }

    /// Writes the password, or removes it for nil or empty. False when the store refused.
    @discardableResult
    public func setPassword(_ value: String?) -> Bool {
        lock.withLock { _ in secrets.set(Key.password, value?.isEmpty == false ? value : nil) }
    }

    /// The network to join. An empty name reads as none.
    public var network: String? {
        get { (read(Key.network) as? String).flatMap { $0.isEmpty ? nil : $0 } }
        set { write(newValue, Key.network) }
    }

    /// Set just before `disablesleep 1` and cleared just after `disablesleep 0`, so a launch after a
    /// crash knows to put sleep back.
    public var engaged: Bool {
        get { read(Key.engaged) as? Bool ?? false }
        set { write(newValue, Key.engaged) }
    }

    /// The marker an earlier version left behind, for launch recovery only: every other check reads
    /// `engaged`, so a marker the installed app's older version sets while this one runs is never
    /// acted on after launch.
    public var legacyEngaged: Bool { legacy?.object(forKey: Key.legacyEngaged) as? Bool ?? false }

    /// Clears the earlier version's marker: only once sleep is back.
    public func clearLegacyEngaged() { legacy?.removeObject(forKey: Key.legacyEngaged) }

    private func read(_ key: String) -> Any? {
        if let defaults { return defaults.object(forKey: key) }
        return lock.withLock { _ in memory[key] }
    }

    private func write(_ value: Any?, _ key: String) {
        if let defaults { defaults.set(value, forKey: key); return }
        lock.withLock { _ in memory[key] = value }
    }
}
