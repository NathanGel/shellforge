// Ported from AiTerm (app/Sources/AiTermCore/Keychain.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Security

public protocol SecretStore {
    func get(_ key: String) -> String?
    /// `false` when the secret could not be stored, so a caller can say so instead of silently
    /// losing the token.
    @discardableResult func set(_ key: String, _ value: String?) -> Bool
}

/// Sendable, so a launch can read it off the main actor as it reads the Keychain.
public final class MemorySecretStore: SecretStore, Sendable {
    private let storage = Locked<[String: String]>([:])
    var values: [String: String] {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
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

/// What tells one version of an item from the next without reading its secret: macOS shows no
/// prompt for an item's attributes. `modified` is the Keychain's modification date, which the login
/// keychain keeps in whole seconds; `writeID` is a fresh value every write stores beside the data, so
/// two writes within one second still differ.
struct KeychainStamp: Equatable, Sendable {
    var modified: Date?
    var writeID: Data?
    var exists = true

    static let absent = KeychainStamp(modified: nil, writeID: nil, exists: false)
}

/// The Keychain's generic-password items under one service, one per account. A stand-in replaces
/// it in tests, which never touch the real Keychain.
protocol KeychainItems: Sendable {
    func read(_ account: String) -> KeychainRead
    /// The item's stamp, from an attributes-only query that shows no prompt. `.absent` when there
    /// is no item, `nil` when its attributes could not be read.
    func stamp(_ account: String) -> KeychainStamp?
    /// Stores `data` with `writeID` beside it, which the item's stamp then carries.
    func write(_ account: String, _ data: Data, writeID: Data) -> Bool
    func delete(_ account: String) -> Bool
}

struct SystemKeychainItems: KeychainItems {
    let service: String
    /// Pinned to the login keychain: on a build with the data-protection entitlement an unpinned
    /// update or delete could land there instead, and the vault must stay one login item.
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }

    func read(_ account: String) -> KeychainRead {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess: return (out as? Data).map(KeychainRead.found) ?? .refused
        case errSecItemNotFound: return .missing
        default: return .refused
        }
    }

    /// Asks for attributes only, never the data, so it shows no prompt.
    func stamp(_ account: String) -> KeychainStamp? {
        var q = query(account); q[kSecReturnAttributes as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        switch SecItemCopyMatching(q as CFDictionary, &out) {
        case errSecSuccess:
            guard let attributes = out as? [String: Any] else { return nil }
            return KeychainStamp(modified: attributes[kSecAttrModificationDate as String] as? Date,
                                 writeID: attributes[kSecAttrGeneric as String] as? Data)
        case errSecItemNotFound: return .absent
        default: return nil
        }
    }

    /// Updates in place when the item exists and adds it otherwise, rather than deleting first: a
    /// delete that succeeds followed by an add that fails would throw the secret away.
    func write(_ account: String, _ data: Data, writeID: Data) -> Bool {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data, kSecAttrGeneric as String: writeID] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var q = query(account); q[kSecValueData as String] = data; q[kSecAttrGeneric as String] = writeID
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
///
/// Other processes share the item (a release build and a dev build running together). Before each
/// write the item's stamp, which shows no prompt, says whether one of them wrote since this process
/// read it; if so the item is read again and only this change is applied on top, so their entries
/// survive. A lock on a file in the support folder (`VaultLock`) keeps a second process from writing
/// between that check and the write, and each write is read back: when the stamp is not the one just
/// written, a process without the lock (an older build) wrote meanwhile, and the change is applied
/// again on top of what it stored.
public final class Keychain: SecretStore, Sendable {
    public static let shared = Keychain()
    static let account = "secrets"
    /// Earlier versions kept each token in an item of its own. They move into the one item the
    /// first time it is missing, and go once it holds them.
    static let separateAccounts = ["jira.token", "gitlab.token", "github.token", "backpack.password"]

    private struct Loaded {
        var secrets: [String: String]
        /// The item's stamp when `secrets` was read or last written. `nil` is unknown, which counts
        /// as changed.
        var stamp: KeychainStamp?
    }

    /// How many times a write whose read-back shows another writer's stamp is applied again.
    static let retries = 3

    private let items: any KeychainItems
    /// `nil` takes no lock across processes, for tests that need none.
    private let lock: VaultLock?
    /// `nil` until the item has been read. A refused read leaves it `nil`, so a later call asks again.
    private let state = Locked<Loaded?>(nil)

    public convenience init(service: String = "io.github.nathangel.shellforge") {
        self.init(items: SystemKeychainItems(service: service), lock: .standard)
    }

    init(items: any KeychainItems, lock: VaultLock? = nil) {
        self.items = items
        self.lock = lock
    }

    public func get(_ key: String) -> String? {
        state.withLock { load(&$0)?[key] }
    }

    @discardableResult
    public func set(_ key: String, _ value: String?) -> Bool {
        mutate { $0[key] = value } == .written
    }

    /// Reads the item now if it has not been read yet, so the one Keychain prompt comes at launch
    /// rather than at whatever moment the first secret is needed.
    public func warm() {
        state.withLock { _ = load(&$0) }
    }

    // MARK: Binary entries

    /// What reading a binary entry came to. `unavailable` is not `missing`: the item could not be
    /// read (the person clicked Deny), and treating that as empty would invite a write over it.
    public enum VaultRead: Equatable {
        case found(Data)
        case missing
        case unavailable
    }

    /// What a write came to. `unavailable`: the item could not be read (the person clicked Deny),
    /// so nothing was written. `failed`: the Keychain refused the write. Either way the Keychain
    /// is unchanged, unless another writer kept replacing the item until the retries ran out.
    public enum VaultWrite: Equatable {
        case written
        case unavailable
        case failed
    }

    /// What `setDataIfMissing` came to. `present` holds the value the entry already had, which was
    /// left alone.
    public enum VaultInsert: Equatable {
        case inserted
        case present(Data)
        case unavailable
        case failed
    }

    /// Binary entries live in the same JSON object as the string secrets, under a prefixed key with
    /// a base64 value, so the item stays `[String: String]` and earlier builds ignore them.
    static func vaultKey(service: String, account: String) -> String { "upgradeSafe:\(service):\(account)" }
    /// Set beside an entry moved in from an item of its own, until that item is deleted. Only then
    /// may a later read delete the old item: any other copy there was written after the move, by an
    /// older build, and may be newer than the entry.
    static func reapKey(service: String, account: String) -> String { "upgradeSafeReap:\(service):\(account)" }

    public func data(service: String, account: String) -> VaultRead {
        state.withLock { loaded in
            guard let all = load(&loaded) else { return .unavailable }
            return Self.decode(all, service: service, account: account).map(VaultRead.found) ?? .missing
        }
    }

    /// `nil` removes the entry. A write also clears the entry's pending reap: it is newer than any
    /// old copy. Anything but `written` leaves the Keychain unchanged.
    @discardableResult
    public func setData(_ data: Data?, service: String, account: String) -> VaultWrite {
        mutate { secrets in
            secrets[Self.vaultKey(service: service, account: account)] = data?.base64EncodedString()
            secrets[Self.reapKey(service: service, account: account)] = nil
        }
    }

    /// Stores `data` only if the entry is still missing, checked and written under the one lock, so
    /// a value another thread stored meanwhile is never overwritten by an older one. `reapPending`
    /// marks, in the same write, that an old copy elsewhere is still to be deleted.
    public func setDataIfMissing(_ data: Data, service: String, account: String, reapPending: Bool) -> VaultInsert {
        var present: Data?
        let result = mutate { secrets in
            present = Self.decode(secrets, service: service, account: account)
            guard present == nil else { return }
            secrets[Self.vaultKey(service: service, account: account)] = data.base64EncodedString()
            if reapPending { secrets[Self.reapKey(service: service, account: account)] = "1" }
        }
        switch result {
        case .written: return present.map(VaultInsert.present) ?? .inserted
        case .unavailable: return .unavailable
        case .failed: return .failed
        }
    }

    /// Whether the entry was moved in and its old copy is still to be deleted. Answered from memory
    /// once the item has been read.
    public func reapPending(service: String, account: String) -> Bool {
        state.withLock { loaded in
            load(&loaded)?[Self.reapKey(service: service, account: account)] != nil
        }
    }

    @discardableResult
    public func clearReapPending(service: String, account: String) -> VaultWrite {
        mutate { $0[Self.reapKey(service: service, account: account)] = nil }
    }

    /// Reads the item from the Keychain itself, not the cache, and says whether its entry holds
    /// `data`. The migration calls it before deleting an old copy, once per moved item. It may
    /// prompt if the person chose Allow rather than Always Allow, which is acceptable for a one-time
    /// move. The cache is left as it was.
    public func confirmStored(_ data: Data, service: String, account: String) -> Bool {
        state.withLock { _ in
            guard case .found(let raw) = items.read(Self.account),
                  let all = try? JSONDecoder().decode([String: String].self, from: raw) else { return false }
            return Self.decode(all, service: service, account: account) == data
        }
    }

    private static func decode(_ secrets: [String: String], service: String, account: String) -> Data? {
        secrets[vaultKey(service: service, account: account)].flatMap { Data(base64Encoded: $0) }
    }

    // MARK: Reading and writing the item

    /// Applies `change` to the secrets and stores the result. When another process wrote the item
    /// since this one read it, the change goes on top of what the item holds now, not the copy in
    /// memory. A change that changes nothing writes nothing. The first read of the item, which may
    /// show a Keychain prompt, comes before the lock across processes, so that prompt does not hold
    /// it; checking and writing run under it, taken once. A prompt can still come while it is held:
    /// the read again after another writer's stamp, and the one-time move of the earlier items.
    private func mutate(_ change: (inout [String: String]) -> Void) -> VaultWrite {
        state.withLock { loaded in
            if loaded == nil {
                let stamp = items.stamp(Self.account)
                switch items.read(Self.account) {
                case .found(let data):
                    guard let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { return .unavailable }
                    loaded = Loaded(secrets: secrets, stamp: stamp)
                case .refused:
                    return .unavailable
                case .missing:
                    // The earlier items are moved under the lock, by `mutateLocked`'s load.
                    break
                }
            }
            return exclusive(holdingLock: false) { mutateLocked(change, &loaded) }
        }
    }

    /// After the write the item is read back (`readBack`). Only when the write is this one's are the
    /// secrets kept; otherwise another writer stored the item in between, so it is read again and
    /// the change applied on top, at most `retries` more times. Caching this process's secrets
    /// under the other writer's stamp would let the next write drop its entries.
    private func mutateLocked(_ change: (inout [String: String]) -> Void, _ loaded: inout Loaded?) -> VaultWrite {
        for _ in 0...Self.retries {
            guard load(&loaded, holdingLock: true) != nil else { return .unavailable }
            if loaded?.stamp == nil || items.stamp(Self.account) != loaded?.stamp {
                loaded = nil
                guard load(&loaded, holdingLock: true) != nil else { return .unavailable }
            }
            guard let current = loaded?.secrets else { return .unavailable }
            var next = current
            change(&next)
            if next == current { return .written }
            let writeID = Self.newWriteID()
            guard store(next, writeID: writeID) else { return .failed }
            if case .ours(let stamp) = readBack(next, writeID: writeID) {
                loaded = Loaded(secrets: next, stamp: stamp)
                return .written
            }
            loaded = nil
        }
        return .failed
    }

    /// Runs `body` under the lock across processes, unless the caller already holds it or there is
    /// none.
    private func exclusive<T>(holdingLock: Bool, _ body: () -> T) -> T {
        guard !holdingLock, let lock else { return body() }
        return lock.withLock(body)
    }

    private enum ReadBack {
        /// The item holds this write. The stamp is `nil` when its attributes could not be read,
        /// which counts as changed, so the next write reads the item again.
        case ours(KeychainStamp?)
        case anotherWriters
    }

    /// Whether the item holds the write just made: its stamp carries `writeID`, or, for a delete,
    /// there is no item. When the stamp cannot be read, one read of the value settles it, rather
    /// than counting an unreadable stamp as another writer and writing again.
    private func readBack(_ secrets: [String: String], writeID: Data) -> ReadBack {
        if let after = items.stamp(Self.account) {
            return (secrets.isEmpty ? after == .absent : after.writeID == writeID) ? .ours(after) : .anotherWriters
        }
        switch items.read(Self.account) {
        case .missing: return secrets.isEmpty ? .ours(nil) : .anotherWriters
        case .found(let data):
            let stored = try? JSONDecoder().decode([String: String].self, from: data)
            return stored == secrets ? .ours(nil) : .anotherWriters
        case .refused:
            // The Keychain took the write and nothing says otherwise; the next write reads again.
            return .ours(nil)
        }
    }

    private static func newWriteID() -> Data {
        withUnsafeBytes(of: UUID().uuid) { Data($0) }
    }

    /// The stamp is taken before the data: a write that lands between the two then looks like a
    /// change, and the next write reads again, rather than the other way round. `holdingLock` says
    /// whether the caller holds the lock across processes, which moving the earlier items takes.
    private func load(_ loaded: inout Loaded?, holdingLock: Bool = false) -> [String: String]? {
        if let loaded { return loaded.secrets }
        let stamp = items.stamp(Self.account)
        switch items.read(Self.account) {
        case .found(let data):
            guard let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
            loaded = Loaded(secrets: secrets, stamp: stamp)
        case .missing:
            guard let moved = moveSeparateItems(holdingLock: holdingLock, stampBefore: stamp) else { return nil }
            loaded = Loaded(secrets: moved.secrets, stamp: moved.stamp)
        case .refused:
            return nil
        }
        return loaded?.secrets
    }

    /// Reads the earlier items, which may prompt, before taking the lock; then, under it, stores
    /// them as the one item if it is still missing, and deletes them only once the read-back says
    /// the item holds them. The stamp returned is the one to cache.
    private func moveSeparateItems(holdingLock: Bool, stampBefore: KeychainStamp?) -> (secrets: [String: String], stamp: KeychainStamp?)? {
        var moved: [String: String] = [:]
        for account in Self.separateAccounts {
            switch items.read(account) {
            case .found(let data): moved[account] = String(decoding: data, as: UTF8.self)
            case .missing: continue
            case .refused: return nil
            }
        }
        guard !moved.isEmpty else { return (moved, stampBefore) }
        return exclusive(holdingLock: holdingLock) {
            // Another process moved them meanwhile: what it stored is unknown here, so the stamp is
            // too, and the next write reads the item.
            guard items.stamp(Self.account) == .absent else { return (moved, nil) }
            let writeID = Self.newWriteID()
            guard store(moved, writeID: writeID) else { return (moved, stampBefore) }
            guard case .ours(let stamp) = readBack(moved, writeID: writeID) else { return (moved, nil) }
            for account in moved.keys { _ = items.delete(account) }
            return (moved, stamp)
        }
    }

    /// No secrets left is no item at all.
    private func store(_ secrets: [String: String], writeID: Data) -> Bool {
        if secrets.isEmpty { return items.delete(Self.account) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(secrets) else { return false }
        return items.write(Self.account, data, writeID: writeID)
    }
}
