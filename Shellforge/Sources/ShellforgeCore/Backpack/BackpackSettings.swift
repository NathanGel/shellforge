// Ported from AiTerm (app/Sources/AiTermCore/Backpack/BackpackSettings.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Backpack Mode's preferences and its crash marker. In `UserDefaults` when given one, as
/// `InterfaceSettings` is; in memory without, for previews and an app built without the live ports.
/// The network's password goes to `secrets` — the Keychain in the app — never to defaults.
///
/// `@unchecked Sendable`: `UserDefaults` is documented thread-safe but not marked `Sendable`; the
/// memory copy and every `secrets` call are taken under `lock`. (A `Mutex` cannot hold them: neither
/// `Any` nor a `SecretStore` is `Sendable`.)
public final class BackpackSettings: @unchecked Sendable {
    /// The battery level, in percent, at or below which the mode turns itself off on battery power.
    /// Fixed (spec 2026-10-05): nobody tunes it, so nothing shows it.
    public static let cutoff = 10

    private enum Key {
        static let network = "backpack.network"
        static let engaged = "backpack.engaged"
        static let password = "backpack.password"
    }

    private let defaults: UserDefaults?
    private let secrets: any SecretStore
    private let lock = Locked(())
    private var memory: [String: Any] = [:]

    public init(defaults: UserDefaults?, secrets: any SecretStore = MemorySecretStore()) {
        self.defaults = defaults
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

    private func read(_ key: String) -> Any? {
        if let defaults { return defaults.object(forKey: key) }
        return lock.withLock { _ in memory[key] }
    }

    private func write(_ value: Any?, _ key: String) {
        if let defaults { defaults.set(value, forKey: key); return }
        lock.withLock { _ in memory[key] = value }
    }
}
