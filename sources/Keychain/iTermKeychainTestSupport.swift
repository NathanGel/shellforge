//
//  iTermKeychainTestSupport.swift
//  iTerm2
//
//  Test-only launch hook to reset the data-protection keychain between migration
//  tests. Because those items are entitlement-gated, only the signed `make run-keychain`
//  build can read or delete them, and the plain `security` CLI cannot. This lets that
//  build purge the app's own data-protection items (scoped to our access group, so it
//  can never touch another app's) when launched with a specific flag, then quit.
//
//  This whole class is wrapped in `#if ITERM_DEBUG` (defined only in the Development
//  configuration via OTHER_SWIFT_FLAGS), so it PHYSICALLY does not exist in a
//  Beta/Nightly/Deployment binary, not merely uncalled. Its single call site in
//  iTermApplicationDelegate is likewise `#ifdef ITERM_DEBUG`. It also only acts when the
//  specific launch flag is present. See `make purge-keychain-test`.
//
//  It also holds iTermFakeKeychains, the stand-ins ModernTests install in place of the
//  real data-protection keychain, login keychain and vault.
//

import Foundation
import ShellforgeCore

#if ITERM_DEBUG
@objc(iTermKeychainTestSupport)
final class iTermKeychainTestSupport: NSObject {
    private static let purgeFlag = "--iterm2-purge-data-protection-keychain-for-testing"
    private static let resultPath = "/tmp/iterm2-keychain-purge-result.txt"

    /// If the purge launch flag is present, delete the app's data-protection keychain
    /// items, write a one-line result to a temp file for the caller, and exit before the
    /// rest of launch (so no keychain read races the purge).
    @objc static func handlePurgeLaunchFlagIfPresent() {
        guard CommandLine.arguments.contains(purgeFlag) else { return }
        let count = iTermUpgradeSafeKeychain.purgeAllDataProtectionItemsForTesting()
        let message = "purged data-protection keychain: matched \(count.map(String.init) ?? "n/a (no access group)") item(s)\n"
        try? message.write(toFile: resultPath, atomically: true, encoding: .utf8)
        exit(0)
    }
}

/// Stand-ins for the three stores iTermUpgradeSafeKeychain uses, so its tests never touch the
/// real Keychain. Each store is a dictionary keyed by service and account; a status set in one
/// of the `…Fails` dictionaries answers that call instead, the way a denied prompt or a missing
/// entitlement would. `install()` puts them in place and returns what to restore afterwards.
final class iTermFakeKeychains {
    var dataProtection: [String: Data] = [:]
    var legacy: [String: Data] = [:]
    var vault: [String: Data] = [:]

    /// `true` is a build without the keychain-access-groups entitlement.
    var dataProtectionUnavailable = false
    /// The person clicked Deny on the vault’s one prompt: reads are `unavailable`, writes fail.
    var vaultUnavailable = false
    var legacyReadFails: [String: OSStatus] = [:]
    var legacyDeleteFails: [String: OSStatus] = [:]
    var vaultWriteFails = false

    private(set) var legacyReads: [String: Int] = [:]
    private(set) var legacyDeletes: [String: Int] = [:]
    private(set) var legacyWrites: [String: Int] = [:]
    private(set) var vaultReads = 0
    /// The app may reach the keychain from another thread while a test runs.
    private let lock = NSRecursiveLock()

    static func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

    func install() -> iTermUpgradeSafeKeychain.Stores {
        let previous = iTermUpgradeSafeKeychain.stores
        iTermUpgradeSafeKeychain.stores = stores
        return previous
    }

    private var stores: iTermUpgradeSafeKeychain.Stores {
        iTermUpgradeSafeKeychain.Stores(
            dataProtectionCopy: { [self] service, account in lock.withLock {
                if dataProtectionUnavailable { return (errSecMissingEntitlement, nil) }
                guard let data = dataProtection[Self.key(service, account)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            } },
            dataProtectionUpsert: { [self] data, service, account, _ in lock.withLock {
                if dataProtectionUnavailable { return errSecMissingEntitlement }
                dataProtection[Self.key(service, account)] = data
                return errSecSuccess
            } },
            dataProtectionDelete: { [self] service, account in lock.withLock {
                if dataProtectionUnavailable { return errSecMissingEntitlement }
                return dataProtection.removeValue(forKey: Self.key(service, account)) == nil ? errSecItemNotFound : errSecSuccess
            } },
            legacyCopy: { [self] service, account in lock.withLock {
                let key = Self.key(service, account)
                legacyReads[key, default: 0] += 1
                if let status = legacyReadFails[key] { return (status, nil) }
                guard let data = legacy[key] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            } },
            legacyUpsert: { [self] data, service, account, _ in lock.withLock {
                let key = Self.key(service, account)
                legacyWrites[key, default: 0] += 1
                legacy[key] = data
                return errSecSuccess
            } },
            legacyDelete: { [self] service, account in lock.withLock {
                let key = Self.key(service, account)
                legacyDeletes[key, default: 0] += 1
                if let status = legacyDeleteFails[key] { return status }
                return legacy.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
            } },
            vaultRead: { [self] service, account in lock.withLock {
                vaultReads += 1
                if vaultUnavailable { return .unavailable }
                return vault[Self.key(service, account)].map { .found($0) } ?? .missing
            } },
            vaultWrite: { [self] data, service, account in lock.withLock {
                if vaultUnavailable || vaultWriteFails { return false }
                vault[Self.key(service, account)] = data
                return true
            } })
    }
}
#endif
