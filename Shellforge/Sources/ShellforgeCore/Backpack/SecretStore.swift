// Ported from AiTerm (app/Sources/AiTermCore/Keychain.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Security

public protocol SecretStore {
    func get(_ key: String) -> String?
    /// `false` when the secret could not be stored, so a caller can say so instead of silently
    /// losing the token.
    @discardableResult func set(_ key: String, _ value: String?) -> Bool
}

public final class MemorySecretStore: SecretStore {
    var values: [String: String] = [:]
    public init() {}
    public func get(_ key: String) -> String? { values[key] }
    @discardableResult public func set(_ key: String, _ value: String?) -> Bool { values[key] = value; return true }
}

/// What reading one Keychain item came to. `refused` is not `missing`: the person denied access,
/// or the item could not be read, and writing over it would throw away what it holds.
enum KeychainRead: Equatable {
    case found(Data)
    case missing
    case refused
}

/// The Keychain's generic-password items under one service, one per account. A stand-in replaces
/// it in tests, which never touch the real Keychain.
protocol KeychainItems: Sendable {
    func read(_ account: String) -> KeychainRead
    func write(_ account: String, _ data: Data) -> Bool
    func delete(_ account: String) -> Bool
}

struct SystemKeychainItems: KeychainItems {
    let service: String
    private func query(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }

    func read(_ account: String) -> KeychainRead {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess: return (out as? Data).map(KeychainRead.found) ?? .refused
        case errSecItemNotFound: return .missing
        default: return .refused
        }
    }

    /// Updates in place when the item exists and adds it otherwise, rather than deleting first: a
    /// delete that succeeds followed by an add that fails would throw the secret away.
    func write(_ account: String, _ data: Data) -> Bool {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var q = query(account); q[kSecValueData as String] = data
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    func delete(_ account: String) -> Bool {
        let status = SecItemDelete(query(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Every Shellforge secret, kept as one JSON object in one Keychain item. macOS asks for access per
/// item, so one item is one prompt where an item per secret was one per secret. The item is read once per
/// process and kept: `shared` is the one the app uses, so every reader after the first, on any
/// thread, is answered from memory, and readers that arrive together wait for that first read
/// instead of each asking.
public final class Keychain: SecretStore, Sendable {
    public static let shared = Keychain()
    static let account = "secrets"
    /// Earlier versions kept each token in an item of its own. They move into the one item the
    /// first time it is missing, and go once it holds them.
    static let separateAccounts = ["jira.token", "gitlab.token", "github.token", "backpack.password"]

    private let items: any KeychainItems
    /// `nil` until the item has been read. A refused read leaves it `nil`, so a later call asks again.
    private let secrets = Locked<[String: String]?>(nil)

    public convenience init(service: String = "io.github.nathangel.shellforge") { self.init(items: SystemKeychainItems(service: service)) }
    init(items: any KeychainItems) { self.items = items }

    public func get(_ key: String) -> String? {
        secrets.withLock { load(&$0)?[key] }
    }

    @discardableResult
    public func set(_ key: String, _ value: String?) -> Bool {
        secrets.withLock { cached in
            guard var next = load(&cached) else { return false }
            next[key] = value
            guard store(next) else { return false }
            cached = next
            return true
        }
    }

    private func load(_ cached: inout [String: String]?) -> [String: String]? {
        if let cached { return cached }
        switch items.read(Self.account) {
        case .found(let data):
            cached = try? JSONDecoder().decode([String: String].self, from: data)
        case .missing:
            cached = moveSeparateItems()
        case .refused:
            break
        }
        return cached
    }

    private func moveSeparateItems() -> [String: String]? {
        var moved: [String: String] = [:]
        for account in Self.separateAccounts {
            switch items.read(account) {
            case .found(let data): moved[account] = String(decoding: data, as: UTF8.self)
            case .missing: continue
            case .refused: return nil
            }
        }
        if !moved.isEmpty, store(moved) {
            for account in moved.keys { _ = items.delete(account) }
        }
        return moved
    }

    /// No secrets left is no item at all.
    private func store(_ secrets: [String: String]) -> Bool {
        if secrets.isEmpty { return items.delete(Self.account) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(secrets) else { return false }
        return items.write(Self.account, data)
    }
}
