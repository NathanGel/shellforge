//
//  iTermUpgradeSafeKeychain.swift
//  iTerm2
//
//  A drop-in replacement for the three generic-password SecItem primitives
//  (copy / add / delete) that stores items in the macOS DATA-PROTECTION keychain
//  instead of the legacy login keychain, and transparently migrates any value
//  still living in the login keychain on first read.
//
//  Why this exists: login-keychain items are gated by an ACL that trusts only the
//  exact code signature that wrote them. After an app upgrade the running binary's
//  signature differs from the writer's, so every first read pops the "iTerm2 wants
//  to use your confidential information" confirmation prompt. Data-protection
//  keychain items are instead authorized by the app's keychain-access-group
//  entitlement, which is stable across any build the same team signs. So once an
//  item lives here, upgrades read it silently: no prompt, ever.
//
//  This helper deliberately speaks the raw (OSStatus, Data?) SecItem vocabulary
//  rather than a richer result type, so existing call sites (CompanionMacIdentity,
//  CompanionPushNonceRegistry, AITermControllerObjC) keep their own carefully
//  tuned interpretation of a read result (32-byte validation, absent-vs-unreadable,
//  hard-error caching policy) unchanged and only swap the storage layer underneath.
//
//  MIGRATION SAFETY (read path): the login-keychain copy is deleted (reaped) ONLY after
//  the data-protection copy is written AND read back byte-for-byte. If either half fails
//  the login copy is left intact and its value is still returned, so the worst case is
//  "keeps prompting like before" rather than "secret lost." The data-protection reads and
//  writes pin kSecAttrAccessGroup EXPLICITLY (read from our own entitlement, never
//  hardcoded, matched by suffix) so a later launch reads the SAME group the write used;
//  relying on the implicit default group previously caused a migrated item to read as
//  errSecItemNotFound on a subsequent launch.
//
//  WRITE SAFETY: `setGenericPassword` is update-or-insert (never delete-then-add), so a
//  transient write failure cannot destroy the prior value. On success it reaps any
//  lingering login-keychain copy so a rotate/clear erases the old secret. On a hard error
//  (locked keychain) it falls back to the LOGIN keychain ONLY when DP has no item for this
//  account. If a hard error occurs while a STALE data-protection item exists, we
//  do NOT write to login - reads would hit the stale DP value and never consult login
//  (migration fires only on a DP miss), so the fresh value survives only in the caller's
//  in-memory cache for the session rather than being silently shadowed.
//
//  NO DATA-PROTECTION KEYCHAIN (errSecMissingEntitlement: Shellforge's ad-hoc signed
//  builds): reads, writes and deletes use the VAULT instead, one entry each in Shellforge's
//  one Keychain item (ShellforgeCore's Keychain.shared), which is read once per process, so
//  an update prompts once rather than once per secret. A vault miss reads the per-item login
//  copy once, moves it in (only if the entry is still missing), confirms the read-back from
//  the Keychain itself, and only then deletes the login copy; a refused read (vault or login)
//  changes nothing and reports the refused status. A write goes to the vault and then reaps
//  any leftover login copy. A vault hit deletes a login copy only when this build moved it in
//  and had not yet deleted it; any other login copy was written later, by an older build, and
//  is left alone. See "The vault" below.
//
//  A BUILD WITH THE ENTITLEMENT (a future Developer ID build) still finds the secrets an
//  ad-hoc build kept in the vault: on a data-protection miss it reads the vault before the
//  login copy, and moves a vault entry into the data-protection keychain under the same rules
//  (write, read back, and only then remove the vault entry). That costs at most one vault
//  prompt, once.
//
//  Clearing a secret must be an explicit `deleteGenericPassword`, NOT a write of empty
//  Data: an empty kSecValueData does not round-trip reliably. deleteGenericPassword
//  removes EVERY copy and returns false if a copy may survive, since a surviving login
//  copy would resurrect via migration on the next read.
//

import Foundation
import CryptoKit
import ShellforgeCore

enum iTermUpgradeSafeKeychain {
    // MARK: - Public SecItem-shaped surface

    /// Data-protection-keychain analog of SecItemCopyMatching for a single generic
    /// password, with transparent one-time migration from the login keychain.
    ///
    /// Returns exactly what a SecItemCopyMatching against the data-protection
    /// keychain would return once migration has completed: `(errSecSuccess, data)`
    /// when present, `(errSecItemNotFound, nil)` when genuinely absent from both
    /// stores, or a hard error status (with nil data) otherwise. `accessible` is the
    /// kSecAttrAccessible value used when a migrated value is (re)written into the
    /// data-protection keychain, so the caller controls this-device-only vs
    /// transferable semantics per item family.
    static func copyGenericPassword(service: String,
                                    account: String,
                                    accessible: CFString) -> (OSStatus, Data?) {
        let (dpStatus, dpData) = dataProtectionCopy(service: service, account: account)
        switch planAfterDataProtectionRead(status: dpStatus) {
        case .useDataProtectionResult:
            if dpStatus != errSecSuccess {
                // Present-but-unreadable or another hard error: the item is neither
                // served nor migrated, and we deliberately do NOT fall through to the
                // login keychain (that would mask the error as absent). The happy
                // path (a clean read) is intentionally left unlogged to avoid noise.
                RLog("UpgradeSafeKeychain: data-protection read of \(redactedItemLabel(service, account)) hard-errored (item not served, not migrated): \(describe(dpStatus))")
            }
            return (dpStatus, dpData)
        case .consultLegacy:
            // DLog the miss detail (status + resolved group) so it's available in a debug
            // log without churning the RLog ring on every unconfigured item. Surface only
            // errSecMissingEntitlement as RLog: expected on unsigned/dev builds, but on a
            // SIGNED build it means the entitlement is missing or wrong.
            DLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - data-protection read miss: \(describe(dpStatus)), accessGroup=\(accessGroup ?? "<nil>")")
            if dpStatus == errSecMissingEntitlement {
                DLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - data-protection keychain unavailable (errSecMissingEntitlement); reading the vault. Expected on unsigned/ad-hoc builds; on a signed build the entitlement is missing.")
                return vaultCopy(service: service, account: account)
            }
            // An ad-hoc build may have kept this secret in the vault. Look there, read-only,
            // before the login copy, and move what is found into the data-protection keychain.
            switch stores.vaultRead(service, account) {
            case .found(let vaultValue):
                RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) found in the vault (\(vaultValue.count) bytes); migrating to data-protection keychain")
                migrate(data: vaultValue, service: service, account: account, accessible: accessible, from: .vault)
                return (errSecSuccess, vaultValue)
            case .unavailable:
                // A refused vault is not an empty one: it may hold a newer value than the login
                // copy, so nothing is moved and the item reads as unreadable, not absent.
                RLog("UpgradeSafeKeychain: vault read of \(redactedItemLabel(service, account)) refused or unreadable; item not served, nothing migrated")
                return (vaultRefusedStatus, nil)
            case .missing:
                break
            }
        }
        let (legacyStatus, legacyData) = legacyCopy(service: service, account: account)
        switch planAfterLegacyRead(status: legacyStatus) {
        case .migrate:
            guard shouldMigrateLegacyValue(legacyData), let legacyValue = legacyData else {
                // A present-but-empty login-keychain item is a pre-migration "cleared"
                // tombstone. Nothing meaningful to migrate; reap it and report absent
                // (callers treat absent and "" identically), so it can't be re-read.
                RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) present-but-empty in login keychain (tombstone); reaping and reporting absent")
                reapLegacyReportingStatus(service: service, account: account)
                return (errSecItemNotFound, nil)
            }
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) found in login keychain (\(legacyValue.count) bytes); migrating to data-protection keychain")
            // Best-effort: even if the write half fails, we still hand the caller the
            // value we read from the legacy keychain, so nothing breaks; the migration is
            // retried on the next read.
            migrate(data: legacyValue,
                    service: service,
                    account: account,
                    accessible: accessible,
                    from: .login)
            return (errSecSuccess, legacyValue)
        case .reportAbsent:
            // Genuinely absent from both stores (an unconfigured item, or one already
            // cleared). DLog: this is the common case for any unconfigured item and would
            // otherwise churn the RLog ring on every launch.
            DLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) absent from both the data-protection and login keychains")
            return (errSecItemNotFound, nil)
        case .reportLegacyError:
            RLog("UpgradeSafeKeychain: login-keychain read of \(redactedItemLabel(service, account)) failed, cannot migrate: \(describe(legacyStatus))")
            return (legacyStatus, nil)
        }
    }

    /// Update-or-insert a single generic password. Prefers the data-protection
    /// keychain; on success it also reaps any lingering login-keychain copy so a
    /// rotate/clear erases the old secret. If the data-protection keychain is
    /// unusable (errSecMissingEntitlement, e.g. an unsigned/dev build) the value is
    /// written to the vault instead so nothing is silently dropped. Returns
    /// errSecSuccess when the value was persisted somewhere, otherwise the failing
    /// status. NOT for clearing a value: pass through `deleteGenericPassword` for that
    /// (an empty write does not round-trip and can resurrect via migration).
    @discardableResult
    static func setGenericPassword(_ data: Data,
                                   service: String,
                                   account: String,
                                   accessible: CFString) -> OSStatus {
        let dpStatus = dataProtectionUpsert(data,
                                            service: service,
                                            account: account,
                                            accessible: accessible)
        switch dpStatus {
        case errSecSuccess:
            // Reap any lingering login-keychain copy so a rotate/clear erases the old
            // secret (and a later data-protection read miss can't fall back to a stale
            // value). reapLegacyReportingStatus targets the FILE keychain explicitly (see
            // legacyQuery) so it can't delete the data-protection copy we just wrote.
            // DLog, not RLog: this fires on every write, including per-push nonce saves,
            // which would otherwise churn the RLog ring. reapLegacyReportingStatus already
            // RLogs a genuinely unexpected delete error.
            let reapStatus = reapLegacyReportingStatus(service: service, account: account)
            DLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - wrote to data-protection keychain (accessGroup=\(accessGroup ?? "<nil>")); login reap: \(describe(reapStatus))")
            return errSecSuccess
        case errSecMissingEntitlement:
            // This build cannot use the data-protection keychain (no access group), so the
            // value goes into the vault, where reads look for it too.
            return vaultSet(data, service: service, account: account)
        default:
            // A hard data-protection write error (e.g. errSecInteractionNotAllowed /
            // errSecAuthFailed when the keychain is locked or not yet first-unlocked).
            //
            // Falling back to the login keychain is safe ONLY when the data-protection
            // keychain has NO item for this account (a brand-new secret): a later read then
            // misses DP and migrates the login copy forward. But if a STALE data-protection
            // item already exists, a login write would be permanently shadowed - reads hit
            // the stale DP value and never consult login, because migration fires only on a
            // DP MISS. So fall back only when DP is confirmed empty here; otherwise surface
            // the error and let the caller's in-memory cache hold the fresh value for this
            // session (same as the both-writes-failed case).
            let (existingStatus, _) = dataProtectionCopy(service: service, account: account)
            if existingStatus == errSecItemNotFound {
                RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - data-protection write failed (\(describe(dpStatus))) and no data-protection item exists; falling back to the login keychain")
                return legacyUpsert(data, service: service, account: account, accessible: accessible)
            }
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - data-protection write failed (\(describe(dpStatus))) while a data-protection item is present (read \(describe(existingStatus))); NOT falling back to login, which would be shadowed by the stale value. The new value survives only in the caller's in-memory cache this session.")
            return dpStatus
        }
    }

    /// Remove the item from ALL THREE stores (login, data-protection, vault). Used for
    /// deliberate user actions (unpair, clear key) where fully erasing the secret matters; the
    /// legacy delete may prompt, but the user is present and acting intentionally. Returns true
    /// only if the item is genuinely gone from every store; a false return means a copy may survive and the
    /// caller should treat the clear as not fully done (and can retry).
    ///
    /// ORDER MATTERS: the LOGIN copy is deleted FIRST, and the data-protection copy only
    /// if that succeeded. This guarantees we never reach the one dangerous state -
    /// (data-protection empty, login present) - where a later read misses DP, falls back
    /// to the surviving login copy, and MIGRATES a deliberately-cleared secret back into
    /// DP. In every failure state the item instead just reads as still-present (a clear
    /// that didn't take), which is retryable and never a silent resurrection.
    @discardableResult
    static func deleteGenericPassword(service: String, account: String) -> Bool {
        let legacyStatus = stores.legacyDelete(service, account)
        let legacyOK = (legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound)
        guard legacyOK else {
            // Login delete failed (locked keychain, denied confirmation on the
            // code-signature-gated item, ...). Leave the data-protection copy in place so
            // the item keeps reading as present and cannot resurrect via migration; the
            // clear simply did not take and the caller should retry.
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - login-keychain delete FAILED: \(describe(legacyStatus)). Leaving the data-protection copy in place so the secret can't resurrect; clear did not fully take.")
            return false
        }
        let dpStatus = stores.dataProtectionDelete(service, account)
        // errSecMissingEntitlement means this build has no data-protection keychain
        // (unsigned/ad-hoc): there is nothing to delete there, and the copy that matters is
        // the vault entry. It goes last, after the login copy, for the same reason as above:
        // a surviving login copy beside an empty vault entry would move back in.
        if dpStatus == errSecMissingEntitlement {
            guard stores.vaultWrite(nil, service, account) == .written else {
                RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - vault delete failed (the item could not be read or written). The vault copy may survive; clear did not fully take.")
                return false
            }
            return true
        }
        let dpOK = (dpStatus == errSecSuccess || dpStatus == errSecItemNotFound)
        if !dpOK {
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - data-protection delete failed: \(describe(dpStatus)). A data-protection copy may survive; the item will still read as present (clear did not fully take).")
            return false
        }
        // An entitled build reads the vault on a data-protection miss, so a vault copy an
        // ad-hoc build left behind would bring the cleared secret back. It goes too.
        guard stores.vaultWrite(nil, service, account) == .written else {
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - vault delete failed after the data-protection delete. A vault copy may survive; clear did not fully take.")
            return false
        }
        return true
    }

    // MARK: - The vault (no data-protection keychain)
    //
    // A build without the keychain-access-groups entitlement (Shellforge's ad-hoc signed
    // releases) cannot use the data-protection keychain. Its secrets live in the vault
    // instead: one entry each in Shellforge's one Keychain item, which is read once per
    // process, so an update asks for the Keychain password once rather than once per
    // secret. The same safety rules apply: a login copy is deleted only after the vault
    // holds it and a read-back matches, and a refused read changes nothing.

    /// What `copyGenericPassword` reports when the person refused the vault's Keychain
    /// prompt: the status a refused login-keychain read reports, so callers keep handling
    /// it as present-but-unreadable rather than absent.
    static let vaultRefusedStatus = errSecAuthFailed

    private static func vaultCopy(service: String, account: String) -> (OSStatus, Data?) {
        switch stores.vaultRead(service, account) {
        case .found(let data):
            reapAfterAMove(service: service, account: account)
            return (errSecSuccess, data)
        case .unavailable:
            RLog("UpgradeSafeKeychain: vault read of \(redactedItemLabel(service, account)) refused or unreadable; item not served, nothing moved")
            return (vaultRefusedStatus, nil)
        case .missing:
            break
        }
        // A vault miss: an earlier build may have left the value in the login keychain,
        // unless this process already saw that copy gone.
        guard !legacyCopyGone.access({ $0.contains(legacyGoneKey(service, account)) }) else {
            return (errSecItemNotFound, nil)
        }
        let (legacyStatus, legacyData) = legacyCopy(service: service, account: account)
        switch planAfterLegacyRead(status: legacyStatus) {
        case .migrate:
            guard shouldMigrateLegacyValue(legacyData), let legacyValue = legacyData else {
                RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) present-but-empty in login keychain (tombstone); reaping and reporting absent")
                reapLegacyReportingStatus(service: service, account: account)
                return (errSecItemNotFound, nil)
            }
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) found in login keychain (\(legacyValue.count) bytes); moving it into the vault")
            return (errSecSuccess, moveIntoVault(legacyValue, service: service, account: account))
        case .reportAbsent:
            DLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) absent from both the vault and the login keychain")
            markLegacyCopyGone(service: service, account: account)
            return (errSecItemNotFound, nil)
        case .reportLegacyError:
            RLog("UpgradeSafeKeychain: login-keychain read of \(redactedItemLabel(service, account)) failed, cannot move it into the vault: \(describe(legacyStatus))")
            return (legacyStatus, nil)
        }
    }

    /// A vault hit deletes the login copy only when a move into the vault left that delete
    /// pending (an earlier launch stopped between the two). Any other login copy was written
    /// after the move, by an older or branch build, and may be newer than the vault: it is left
    /// in place, unread.
    private static func reapAfterAMove(service: String, account: String) {
        let key = legacyGoneKey(service, account)
        guard !legacyCopyGone.access({ $0.contains(key) }) else { return }
        guard stores.vaultReapPending(service, account) else {
            if !newerLoginCopyNoted.getAndSet(true) {
                RLog("UpgradeSafeKeychain: vault hit with no pending reap; any login copy is newer than the move and was left in place")
            }
            return
        }
        reapLegacyOnce(service: service, account: account)
    }

    /// Moves a login value in and returns the value the caller should use: the login value, or
    /// the vault's own if another thread stored one meanwhile (that one is newer, and the move
    /// is skipped).
    private static func moveIntoVault(_ data: Data, service: String, account: String) -> Data {
        switch stores.vaultInsert(data, service, account) {
        case .inserted:
            break
        case .present(let newer):
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - the vault gained a value while the login copy was read; keeping it, login copy left in place")
            return newer
        case .unavailable, .failed:
            RLog("UpgradeSafeKeychain: MOVE of \(redactedItemLabel(service, account)) into the vault FAILED at the write. Login-keychain copy kept; will retry next read.")
            return data
        }
        // Read back from the Keychain itself, not the vault's memory, before deleting anything.
        guard stores.vaultConfirm(data, service, account) else {
            RLog("UpgradeSafeKeychain: MOVE of \(redactedItemLabel(service, account)) into the vault wrote but readback did not confirm. Login-keychain copy kept.")
            return data
        }
        let reapStatus = reapLegacyReportingStatus(service: service, account: account)
        if reapStatus == errSecSuccess || reapStatus == errSecItemNotFound {
            markLegacyCopyGone(service: service, account: account)
            stores.vaultClearReapPending(service, account)
        }
        RLog("UpgradeSafeKeychain: moved \(redactedItemLabel(service, account)) into the vault (readback confirmed); login reap: \(describe(reapStatus))")
        return data
    }

    private static func vaultSet(_ data: Data, service: String, account: String) -> OSStatus {
        let status: OSStatus
        switch stores.vaultWrite(data, service, account) {
        case .written:
            // This write is newer than any login copy, so a leftover goes.
            reapLegacyOnce(service: service, account: account)
            DLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - wrote to the vault")
            return errSecSuccess
        case .unavailable:
            status = vaultRefusedStatus
        case .failed:
            status = errSecIO
        }
        // Nothing changed: no login write either, which a vault entry would shadow. The
        // caller's in-memory cache holds the value for this session.
        RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - vault write failed (\(describe(status))); not persisted")
        return status
    }

    private static func legacyGoneKey(_ service: String, _ account: String) -> String {
        "\(service)\u{0}\(account)"
    }

    private static func markLegacyCopyGone(service: String, account: String) {
        let key = legacyGoneKey(service, account)
        legacyCopyGone.mutableAccess { _ = $0.insert(key) }
    }

    /// Deletes a leftover login copy unless this process already saw it gone. A failed
    /// delete is tried again next time.
    private static func reapLegacyOnce(service: String, account: String) {
        let key = legacyGoneKey(service, account)
        guard !legacyCopyGone.access({ $0.contains(key) }) else { return }
        let status = reapLegacyReportingStatus(service: service, account: account)
        if status == errSecSuccess || status == errSecItemNotFound {
            markLegacyCopyGone(service: service, account: account)
            if stores.vaultReapPending(service, account) {
                stores.vaultClearReapPending(service, account)
            }
        }
        if status == errSecSuccess {
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - deleted a leftover login-keychain copy; the vault holds the value")
        }
    }

    // MARK: - Pure migration decisions (unit tested)

    enum DataProtectionReadPlan: Equatable {
        /// The data-protection keychain answered definitively (a value, or a hard
        /// error). Return its result verbatim; do not touch the legacy keychain.
        case useDataProtectionResult
        /// The data-protection keychain has no such item. Fall back to the legacy
        /// keychain, where a pre-migration value may still live.
        case consultLegacy
    }

    /// Given the data-protection read status, decide whether we already have an
    /// answer or must look elsewhere. A genuine not-found sends us to the vault and then
    /// the legacy keychain. So does errSecMissingEntitlement: it means this build cannot use
    /// the data-protection keychain at all (the keychain-access-groups entitlement is
    /// absent or unsigned, e.g. an ad-hoc build), so the vault is the real store and the
    /// login keychain holds what older builds left, rather than reporting every secret
    /// unreadable. A success
    /// is returned as-is, and any other hard error is surfaced rather than masked by
    /// a legacy read (so a locked keychain isn't wrongly reported as absent).
    static func planAfterDataProtectionRead(status: OSStatus) -> DataProtectionReadPlan {
        if status == errSecItemNotFound || status == errSecMissingEntitlement {
            return .consultLegacy
        }
        return .useDataProtectionResult
    }

    enum LegacyReadPlan: Equatable {
        /// The legacy keychain has the value: migrate it into the data-protection
        /// keychain and return it.
        case migrate
        /// Absent from the legacy keychain too: the item genuinely does not exist.
        case reportAbsent
        /// A hard error reading the legacy keychain: surface it; do not migrate.
        case reportLegacyError
    }

    /// Given the legacy read status (only consulted when the data-protection
    /// keychain had nothing), decide the outcome.
    static func planAfterLegacyRead(status: OSStatus) -> LegacyReadPlan {
        if status == errSecSuccess {
            return .migrate
        }
        if status == errSecItemNotFound {
            return .reportAbsent
        }
        return .reportLegacyError
    }

    /// Whether a value successfully read from the legacy keychain is worth migrating
    /// forward. A nil or empty value is a pre-migration "cleared" tombstone (or
    /// nothing) that must be reaped instead of migrated: an empty kSecValueData does
    /// not round-trip, so migrating it would never confirm readback and would re-run
    /// on every launch, and re-storing it could resurrect a key the user cleared.
    static func shouldMigrateLegacyValue(_ data: Data?) -> Bool {
        guard let data else { return false }
        return !data.isEmpty
    }

    // MARK: - Stores

    /// The three places a secret can live: the data-protection keychain, the per-item login
    /// keychain copy, and the vault (one entry each in Shellforge's one Keychain item). The app
    /// uses the real ones; tests install stand-ins (iTermKeychainTestSupport) and never touch
    /// the Keychain.
    struct Stores {
        var dataProtectionCopy: (_ service: String, _ account: String) -> (OSStatus, Data?)
        var dataProtectionUpsert: (_ data: Data, _ service: String, _ account: String, _ accessible: CFString) -> OSStatus
        var dataProtectionDelete: (_ service: String, _ account: String) -> OSStatus
        var legacyCopy: (_ service: String, _ account: String) -> (OSStatus, Data?)
        var legacyUpsert: (_ data: Data, _ service: String, _ account: String, _ accessible: CFString) -> OSStatus
        var legacyDelete: (_ service: String, _ account: String) -> OSStatus
        var vaultRead: (_ service: String, _ account: String) -> Keychain.VaultRead
        /// `nil` removes the entry. Anything but `written` changed nothing.
        var vaultWrite: (_ data: Data?, _ service: String, _ account: String) -> Keychain.VaultWrite
        /// A move in: writes only if the entry is missing, and marks the login copy's reap pending.
        var vaultInsert: (_ data: Data, _ service: String, _ account: String) -> Keychain.VaultInsert
        /// Reads the Keychain itself, not the vault's memory.
        var vaultConfirm: (_ data: Data, _ service: String, _ account: String) -> Bool
        var vaultReapPending: (_ service: String, _ account: String) -> Bool
        var vaultClearReapPending: (_ service: String, _ account: String) -> Void

        static let system = Stores(
            dataProtectionCopy: { systemDataProtectionCopy(service: $0, account: $1) },
            dataProtectionUpsert: { systemDataProtectionUpsert($0, service: $1, account: $2, accessible: $3) },
            dataProtectionDelete: { SecItemDelete(dataProtectionQuery(service: $0, account: $1) as CFDictionary) },
            legacyCopy: { systemLegacyCopy(service: $0, account: $1) },
            legacyUpsert: { systemLegacyUpsert($0, service: $1, account: $2, accessible: $3) },
            legacyDelete: { SecItemDelete(legacyQuery(service: $0, account: $1) as CFDictionary) },
            vaultRead: { Keychain.shared.data(service: $0, account: $1) },
            vaultWrite: { Keychain.shared.setData($0, service: $1, account: $2) },
            vaultInsert: { Keychain.shared.setDataIfMissing($0, service: $1, account: $2, reapPending: true) },
            vaultConfirm: { Keychain.shared.confirmStored($0, service: $1, account: $2) },
            vaultReapPending: { Keychain.shared.reapPending(service: $0, account: $1) },
            vaultClearReapPending: { Keychain.shared.clearReapPending(service: $0, account: $1) })
    }

    private static let installedStores = MutableAtomicObject<Stores>(.system)
    /// Items whose login copy this process has seen gone, so a vault read or write deletes a
    /// leftover once rather than every time.
    private static let legacyCopyGone = MutableAtomicObject<Set<String>>([])

    /// RLogs once per process that a vault hit left a newer login copy alone.
    private static let newerLoginCopyNoted = MutableAtomicObject<Bool>(false)

    static var stores: Stores { installedStores.value }

#if ITERM_DEBUG
    /// Tests only: replaces the stores and forgets which login copies were seen gone, as a new
    /// process would. Not in release builds, so nothing there can swap the Keychain out.
    static func installStoresForTesting(_ newStores: Stores) {
        installedStores.value = newStores
        legacyCopyGone.value = []
        newerLoginCopyNoted.value = false
    }
#endif

    private static func dataProtectionCopy(service: String, account: String) -> (OSStatus, Data?) {
        stores.dataProtectionCopy(service, account)
    }

    private static func dataProtectionUpsert(_ data: Data, service: String, account: String, accessible: CFString) -> OSStatus {
        stores.dataProtectionUpsert(data, service, account, accessible)
    }

    private static func legacyCopy(service: String, account: String) -> (OSStatus, Data?) {
        stores.legacyCopy(service, account)
    }

    private static func legacyUpsert(_ data: Data, service: String, account: String, accessible: CFString) -> OSStatus {
        stores.legacyUpsert(data, service, account, accessible)
    }

    // MARK: - Data-protection keychain I/O

    /// The app's own keychain access group, read from OUR code signature's
    /// keychain-access-groups entitlement so it is never hardcoded (it resolves to the
    /// team-prefixed value, e.g. "TEAMID.com.googlecode.iterm2"). nil on a build with no
    /// such entitlement (unsigned/dev), where callers then omit the group and the
    /// data-protection write fails cleanly, falling back to the vault. Cached:
    /// the signature can't change while the process runs.
    static let accessGroup: String? = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
              let groups = value as? [String],
              !groups.isEmpty else {
            return nil
        }
        // Match by SUFFIX, not array position: correct today (a single entry resolving to
        // "TEAMID.com.googlecode.iterm2"), but if a second access group is ever added
        // (e.g. a shared group for an XPC helper) or the OS reorders them, pinning
        // groups.first could silently target the wrong group and make stored secrets read
        // as errSecItemNotFound. Fall back to the first entry only if none matches.
        return groups.first(where: { $0.hasSuffix(".com.googlecode.iterm2") }) ?? groups.first
    }()

    private static func dataProtectionQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Pin the access group EXPLICITLY rather than relying on the implicit default,
        // so writes and reads always target the same group across launches (relying on
        // the default group is the suspected cause of a migrated-but-unreadable item).
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func systemDataProtectionCopy(service: String, account: String) -> (OSStatus, Data?) {
        var query = dataProtectionQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    private static func systemDataProtectionUpsert(_ data: Data,
                                                   service: String,
                                                   account: String,
                                                   accessible: CFString) -> OSStatus {
        return upsert(baseQuery: dataProtectionQuery(service: service, account: account),
                      data: data,
                      accessible: accessible)
    }

    // Update-then-add-then-update, never delete-then-add.
    //
    // 1. A transient failure (locked keychain, errSecInteractionNotAllowed at launch,
    //    disk pressure) must not destroy a value that is already stored, so we never
    //    delete first: SecItemUpdate an existing item, SecItemAdd a missing one.
    // 2. TOCTOU: two contexts that share the access group (e.g. the main app and the
    //    Notification Service Extension both persisting companion state) can both see
    //    the item missing, both SecItemAdd, and the loser gets errSecDuplicateItem.
    //    That is "someone else already inserted it," NOT a hard failure, so retry it as
    //    an update rather than letting setGenericPassword mistake it for a write error
    //    and spuriously fall back to the login keychain.
    // 3. NOTE: SecItemUpdate applies ONLY kSecValueData, so an already-stored item keeps
    //    its ORIGINAL accessibility; `accessible` takes effect solely on the SecItemAdd
    //    branch. Every (service, account) uses a stable `accessible` today. A future
    //    caller needing to TIGHTEN an existing item's accessibility must delete-then-add
    //    (or update kSecAttrAccessible explicitly); this path would report success while
    //    silently keeping the looser value.
    private static func upsert(baseQuery: [String: Any],
                               data: Data,
                               accessible: CFString) -> OSStatus {
        let attributesToUpdate = [kSecValueData as String: data] as CFDictionary
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate)
        if updateStatus != errSecItemNotFound {
            return updateStatus
        }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessible
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            // Lost the insert race; the item now exists, so update it.
            return SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate)
        }
        return addStatus
    }

    // MARK: - Legacy (login) keychain I/O

    private static func legacyQuery(service: String, account: String) -> [String: Any] {
        // kSecUseDataProtectionKeychain: false is REQUIRED, not optional. On an entitled
        // app, OMITTING it does not reliably mean "file keychain": SecItemCopyMatching
        // read the file item, but SecItemDelete/SecItemUpdate resolved to the DATA-
        // PROTECTION keychain instead, so the reap after a migrate deleted the copy we had
        // just written (readback-confirmed) rather than the old login copy - items with no
        // login fallback (the companion identity key, the push nonce) then vanished on the
        // next launch. Pinning false forces EVERY legacy op (read, delete, upsert) to the
        // file keychain, so it can never touch the data-protection copy.
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func systemLegacyCopy(service: String, account: String) -> (OSStatus, Data?) {
        var query = legacyQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    // Login-keychain write fallback (used when the data-protection keychain is
    // unavailable). Same non-destructive, race-tolerant discipline as the data-protection
    // upsert (see `upsert`).
    private static func systemLegacyUpsert(_ data: Data,
                                           service: String,
                                           account: String,
                                           accessible: CFString) -> OSStatus {
        return upsert(baseQuery: legacyQuery(service: service, account: account),
                      data: data,
                      accessible: accessible)
    }

#if ITERM_DEBUG
    // MARK: - Testing support (compiled out of release builds via ITERM_DEBUG)

    /// Delete EVERY generic-password item the app owns in its data-protection access
    /// group. Test-only: used to reset the data-protection keychain between migration
    /// tests. Scoped to our own access group, so it can only touch items this app wrote,
    /// never another app's. No-op (and returns nil count) when the build has no access
    /// group (unsigned/dev), since it can't have written anything there. This destructive
    /// routine is wrapped in ITERM_DEBUG so it physically does not exist in a release
    /// binary, not merely uncalled.
    @discardableResult
    static func purgeAllDataProtectionItemsForTesting() -> Int? {
        guard let accessGroup else {
            RLog("UpgradeSafeKeychain: purge requested but no access group (unsigned build); nothing to purge")
            return nil
        }
        // Count first (for the log), then delete the whole group in one call.
        var countQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessGroup as String: accessGroup,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let matchStatus = SecItemCopyMatching(countQuery as CFDictionary, &result)
        let count = (result as? [[String: Any]])?.count ?? 0
        countQuery.removeValue(forKey: kSecMatchLimit as String)
        countQuery.removeValue(forKey: kSecReturnAttributes as String)
        let deleteStatus = SecItemDelete(countQuery as CFDictionary)
        RLog("UpgradeSafeKeychain: PURGE of data-protection group '\(accessGroup)' - matched \(count) item(s) (\(describe(matchStatus))), delete \(describe(deleteStatus))")
        return count
    }
#endif

    // MARK: - Migration

    /// Where a migrated value came from, and so which copy goes once the data-protection
    /// keychain holds it.
    private enum MigrationSource {
        case login
        case vault
    }

    private static func migrate(data: Data,
                                service: String,
                                account: String,
                                accessible: CFString,
                                from source: MigrationSource) {
        let writeStatus = dataProtectionUpsert(data,
                                               service: service,
                                               account: account,
                                               accessible: accessible)
        guard writeStatus == errSecSuccess else {
            // Keep the source copy: the value is still returned to the caller and the
            // migration retries next launch (a locked keychain, say). An ad-hoc build never
            // gets here: it has no data-protection keychain and uses the vault instead.
            RLog("UpgradeSafeKeychain: MIGRATION of \(redactedItemLabel(service, account)) FAILED at the data-protection write: \(describe(writeStatus)). Source copy kept; will retry next read.")
            return
        }
        let (readbackStatus, readbackData) = dataProtectionCopy(service: service, account: account)
        guard readbackStatus == errSecSuccess, readbackData == data else {
            // Wrote but can't confirm it read back identically: do NOT reap, or we could
            // lose the only good copy. Log byte counts (never the bytes) so a size
            // mismatch is diagnosable.
            RLog("UpgradeSafeKeychain: MIGRATION of \(redactedItemLabel(service, account)) wrote but readback did not confirm (status \(describe(readbackStatus)); \(readbackData?.count ?? -1) vs \(data.count) bytes). Source copy kept.")
            return
        }
        if source == .vault {
            // The vault entry goes only now that the data-protection copy reads back the same.
            let removed = stores.vaultWrite(nil, service, account)
            RLog("UpgradeSafeKeychain: migrated \(redactedItemLabel(service, account)) from the vault into the data-protection keychain (group \(accessGroup ?? "<none>"), readback confirmed); vault entry removed: \(removed == .written)")
            return
        }
        // The data-protection copy is written and confirmed readable, and it is pinned to
        // an EXPLICIT access group (logged) so a later launch reads the same group. Now
        // reap the code-signature-gated login copy: that delete is what actually stops
        // future upgrade prompts, and it also prevents a data-protection read miss from
        // later falling back to (and re-migrating) a stale value.
        let reapStatus = reapLegacyReportingStatus(service: service, account: account)
        // DIAGNOSTIC (temporary): report the ACTUAL reap status instead of an unconditional
        // "reaped." errSecItemNotFound = the login-keychain delete matched nothing (so the
        // login copy is NOT actually removed if the delete is being scoped to the app's
        // access group while the read searched all groups); -25244 = ownership-locked.
        RLog("UpgradeSafeKeychain: migrated \(redactedItemLabel(service, account)) into the data-protection keychain (group \(accessGroup ?? "<none>"), readback confirmed); login reap: \(describe(reapStatus))")
    }

    // Delete a login-keychain copy after the data-protection copy is authoritative. Returns
    // the delete status. A missing item (errSecItemNotFound) or success is fine; anything
    // else is logged and non-fatal (a stale copy just means the upgrade prompt can recur).
    @discardableResult
    private static func reapLegacyReportingStatus(service: String, account: String) -> OSStatus {
        let status = stores.legacyDelete(service, account)
        if status != errSecSuccess && status != errSecItemNotFound {
            RLog("UpgradeSafeKeychain: \(redactedItemLabel(service, account)) - failed to reap login-keychain copy: \(describe(status)). A stale copy may remain and re-prompt.")
        }
        return status
    }

    /// Human-readable rendering of an OSStatus for logs (never includes secret data).
    private static func describe(_ status: OSStatus) -> String {
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown"
        return "OSStatus \(status) (\(message))"
    }

    // The account (and to a lesser extent the service) identifies which credential
    // this is: a user@host, an API-key label, a password-manager entry name. That
    // inventory must not land in the always-on ring, but the opt-in debug log wants
    // the real identifiers, and even the redacted ring form needs to correlate log
    // lines for the same item. So: full 'service' / 'account' when debug logging is
    // on, and the service plus a short non-reversible digest of the account when off.
    private static func redactedItemLabel(_ service: String, _ account: String) -> RLogRedacted {
        return RLogRedacted(full: "'\(service)' / '\(account)'",
                            redacted: "'\(service)' / account#\(accountDigest(account))")
    }

    private static func accountDigest(_ account: String) -> String {
        let digest = SHA256.hash(data: Data(account.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}
