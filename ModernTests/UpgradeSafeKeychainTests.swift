//
//  UpgradeSafeKeychainTests.swift
//  ModernTests
//
//  Covers the pure migration decisions of iTermUpgradeSafeKeychain: which store a
//  read result routes to. The actual SecItem I/O is intentionally not exercised
//  (it needs a signed host with the keychain-access-group entitlement); these
//  tests pin the branching that decides whether we already have an answer from the
//  data-protection keychain, must fall back to the legacy keychain, or must
//  migrate a legacy value forward.
//

import XCTest
import Security
@testable import iTerm2SharedARC

final class UpgradeSafeKeychainTests: XCTestCase {
    // MARK: - planAfterDataProtectionRead

    func testDataProtectionSuccessIsReturnedVerbatim() {
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterDataProtectionRead(status: errSecSuccess),
            .useDataProtectionResult)
    }

    func testDataProtectionNotFoundConsultsLegacy() {
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterDataProtectionRead(status: errSecItemNotFound),
            .consultLegacy)
    }

    func testMissingEntitlementFallsBackToLegacy() {
        // A build without a usable keychain-access-groups entitlement can't touch the
        // data-protection keychain, so the login keychain is still the real store and
        // we must fall back to it (degrade to old behavior), not surface an error.
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterDataProtectionRead(status: errSecMissingEntitlement),
            .consultLegacy)
    }

    func testDataProtectionHardErrorIsNotMaskedByLegacy() {
        // A locked/denied keychain must surface as an error, NOT be retried against
        // the legacy store (which could then wrongly report the item absent).
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterDataProtectionRead(status: errSecAuthFailed),
            .useDataProtectionResult)
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterDataProtectionRead(status: errSecInteractionNotAllowed),
            .useDataProtectionResult)
    }

    // MARK: - planAfterLegacyRead

    func testLegacyValuePresentTriggersMigration() {
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterLegacyRead(status: errSecSuccess),
            .migrate)
    }

    func testLegacyAbsentReportsAbsent() {
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterLegacyRead(status: errSecItemNotFound),
            .reportAbsent)
    }

    func testLegacyHardErrorIsSurfacedNotMigrated() {
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterLegacyRead(status: errSecAuthFailed),
            .reportLegacyError)
        XCTAssertEqual(
            iTermUpgradeSafeKeychain.planAfterLegacyRead(status: errSecInteractionNotAllowed),
            .reportLegacyError)
    }

    // MARK: - shouldMigrateLegacyValue

    func testNonEmptyLegacyValueIsMigrated() {
        XCTAssertTrue(iTermUpgradeSafeKeychain.shouldMigrateLegacyValue(Data([1, 2, 3])))
    }

    func testEmptyLegacyValueIsNotMigrated() {
        // An empty "" tombstone must be reaped, not migrated (empty kSecValueData
        // does not round-trip, so migrating it would loop forever and could resurrect
        // a cleared key).
        XCTAssertFalse(iTermUpgradeSafeKeychain.shouldMigrateLegacyValue(Data()))
    }

    func testNilLegacyValueIsNotMigrated() {
        XCTAssertFalse(iTermUpgradeSafeKeychain.shouldMigrateLegacyValue(nil))
    }

    // MARK: - Stores, through iTermKeychainTestSupport’s stand-ins

    private let service = "com.example.upgrade-safe-test"
    private let account = "invented-account"
    private let secret = Data("invented-secret-1".utf8)
    private var key: String { iTermFakeKeychains.key(service, account) }
    private var fakes = iTermFakeKeychains()
    private var restore: iTermUpgradeSafeKeychain.Stores?

    override func setUp() {
        super.setUp()
        fakes = iTermFakeKeychains()
        restore = fakes.install()
    }

    override func tearDown() {
        if let restore {
            iTermUpgradeSafeKeychain.stores = restore
        }
        super.tearDown()
    }

    private func readItem() -> (OSStatus, Data?) {
        iTermUpgradeSafeKeychain.copyGenericPassword(service: service, account: account,
                                                     accessible: kSecAttrAccessibleWhenUnlocked)
    }

    private func writeItem(_ data: Data) -> OSStatus {
        iTermUpgradeSafeKeychain.setGenericPassword(data, service: service, account: account,
                                                    accessible: kSecAttrAccessibleWhenUnlocked)
    }

    /// A new process: the stores forget which login copies they saw gone.
    private func relaunch() {
        _ = fakes.install()
    }

    func testWithoutTheEntitlementSecretsLiveInTheVault() {
        fakes.dataProtectionUnavailable = true
        XCTAssertEqual(writeItem(secret), errSecSuccess)
        XCTAssertEqual(fakes.vault[key], secret)
        XCTAssertNil(fakes.legacy[key])
        XCTAssertEqual(fakes.legacyWrites[key, default: 0], 0)

        let (status, data) = readItem()
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(data, secret)
        XCTAssertEqual(fakes.legacyReads[key, default: 0], 0, "a vault hit never asks the login keychain")
    }

    func testAVaultWriteThatFailsIsAFailureAndTouchesNothingElse() {
        fakes.dataProtectionUnavailable = true
        fakes.vaultWriteFails = true
        XCTAssertNotEqual(writeItem(secret), errSecSuccess)
        XCTAssertNil(fakes.vault[key])
        XCTAssertNil(fakes.legacy[key])
    }

    func testALegacyItemMovesInAndIsDeletedAfterReadBack() {
        fakes.dataProtectionUnavailable = true
        fakes.legacy[key] = secret

        let (status, data) = readItem()
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(data, secret)
        XCTAssertEqual(fakes.vault[key], secret)
        XCTAssertNil(fakes.legacy[key])

        // From then on the vault answers, and the login keychain is not asked again.
        XCTAssertEqual(readItem().1, secret)
        XCTAssertEqual(fakes.legacyReads[key], 1)
    }

    func testALegacyItemThatCannotMoveInIsKeptAndStillReturned() {
        fakes.dataProtectionUnavailable = true
        fakes.vaultWriteFails = true
        fakes.legacy[key] = secret

        let (status, data) = readItem()
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(data, secret)
        XCTAssertEqual(fakes.legacy[key], secret, "never deleted before the vault holds it")
        XCTAssertEqual(fakes.legacyDeletes[key, default: 0], 0)
    }

    func testALeftoverLegacyCopyIsReapedNextTime() {
        // The last launch moved the secret in but stopped before deleting the login copy.
        fakes.dataProtectionUnavailable = true
        fakes.vault[key] = secret
        fakes.legacy[key] = Data("invented-old-secret".utf8)
        relaunch()

        let (status, data) = readItem()
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(data, secret, "the vault wins over the leftover")
        XCTAssertNil(fakes.legacy[key])
        XCTAssertEqual(fakes.legacyReads[key, default: 0], 0)

        // Once per process: later reads and writes do not delete again.
        _ = readItem()
        XCTAssertEqual(writeItem(Data("invented-secret-2".utf8)), errSecSuccess)
        XCTAssertEqual(fakes.legacyDeletes[key], 1)
    }

    func testAWriteReapsALeftoverLegacyCopy() {
        fakes.dataProtectionUnavailable = true
        fakes.legacy[key] = Data("invented-old-secret".utf8)
        XCTAssertEqual(writeItem(secret), errSecSuccess)
        XCTAssertEqual(fakes.vault[key], secret)
        XCTAssertNil(fakes.legacy[key])
    }

    func testARefusedLegacyReadLeavesItAlone() {
        fakes.dataProtectionUnavailable = true
        fakes.legacy[key] = secret
        fakes.legacyReadFails[key] = errSecAuthFailed

        let (status, data) = readItem()
        XCTAssertEqual(status, errSecAuthFailed)
        XCTAssertNil(data)
        XCTAssertEqual(fakes.legacy[key], secret)
        XCTAssertNil(fakes.vault[key])
        XCTAssertEqual(fakes.legacyDeletes[key, default: 0], 0)
    }

    func testARefusedVaultReadFailsLikeARefusedLoginRead() {
        fakes.dataProtectionUnavailable = true
        fakes.vaultUnavailable = true
        fakes.legacy[key] = secret

        let (status, data) = readItem()
        XCTAssertEqual(status, errSecAuthFailed)
        XCTAssertNil(data)
        XCTAssertEqual(fakes.legacy[key], secret)
        XCTAssertEqual(fakes.legacyReads[key, default: 0], 0, "a refused vault is not a missing entry")
        XCTAssertNotEqual(writeItem(secret), errSecSuccess)
        XCTAssertEqual(fakes.legacy[key], secret)
    }

    func testDataProtectionIsUsedWhenAvailable() {
        XCTAssertEqual(writeItem(secret), errSecSuccess)
        XCTAssertEqual(fakes.dataProtection[key], secret)

        let other = "invented-other-account"
        let otherKey = iTermFakeKeychains.key(service, other)
        fakes.legacy[otherKey] = secret
        let (status, data) = iTermUpgradeSafeKeychain.copyGenericPassword(service: service, account: other,
                                                                          accessible: kSecAttrAccessibleWhenUnlocked)
        XCTAssertEqual(status, errSecSuccess)
        XCTAssertEqual(data, secret)
        XCTAssertEqual(fakes.dataProtection[otherKey], secret, "migrates into the data-protection keychain")
        XCTAssertNil(fakes.legacy[otherKey])

        XCTAssertTrue(iTermUpgradeSafeKeychain.deleteGenericPassword(service: service, account: account))
        XCTAssertNil(fakes.dataProtection[key])
        XCTAssertTrue(fakes.vault.isEmpty)
        XCTAssertEqual(fakes.vaultReads, 0, "the vault is only the fallback")
    }

    func testDeleteRemovesEveryCopy() {
        fakes.dataProtectionUnavailable = true
        fakes.vault[key] = secret
        fakes.legacy[key] = secret
        XCTAssertTrue(iTermUpgradeSafeKeychain.deleteGenericPassword(service: service, account: account))
        XCTAssertNil(fakes.vault[key])
        XCTAssertNil(fakes.legacy[key])
        XCTAssertEqual(readItem().0, errSecItemNotFound)
        XCTAssertEqual(readItem().0, errSecItemNotFound)
        XCTAssertEqual(fakes.legacyReads[key], 1, "an absent login copy is asked about once per process")
    }

    func testADeleteThatMightLeaveACopyIsNotDone() {
        fakes.dataProtectionUnavailable = true
        fakes.vault[key] = secret
        fakes.legacy[key] = secret
        fakes.legacyDeleteFails[key] = errSecAuthFailed
        XCTAssertFalse(iTermUpgradeSafeKeychain.deleteGenericPassword(service: service, account: account))
        XCTAssertEqual(fakes.vault[key], secret, "kept, so the login copy cannot move back in")

        fakes.legacyDeleteFails = [:]
        fakes.vaultWriteFails = true
        XCTAssertFalse(iTermUpgradeSafeKeychain.deleteGenericPassword(service: service, account: account))
        XCTAssertEqual(fakes.vault[key], secret)
    }
}
