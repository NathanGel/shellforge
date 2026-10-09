// Ported from AiTerm (app/Tests/AiTermCoreTests/KeychainTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore

/// Every secret lives in one Keychain item, read once per process, so macOS asks for access once
/// rather than once per token. The items are a stand-in: a test never touches the real Keychain.
@Suite struct KeychainTests {
    @Test func everySecretLivesInOneItem() {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        #expect(keychain.set("jira.token", "j"))
        #expect(keychain.set("gitlab.token", "g"))
        #expect(keychain.set("github.token", "h"))
        #expect(items.accounts == [Keychain.account])
        #expect(Keychain(items: items).get("gitlab.token") == "g")
    }

    @Test func theItemIsReadOncePerProcess() {
        let items = FakeKeychainItems()
        Keychain(items: items).set("jira.token", "j")
        let keychain = Keychain(items: items)
        items.reads.withLock { $0 = 0 }
        #expect(keychain.get("jira.token") == "j")
        #expect(keychain.get("gitlab.token") == nil)
        keychain.set("github.token", "h")
        #expect(keychain.get("github.token") == "h")
        #expect(items.reads.withLock { $0 } == 1)
    }

    @Test func theSeparateItemsOfEarlierVersionsMoveIntoOne() {
        let items = FakeKeychainItems(["jira.token": "j", "gitlab.token": "g", "github.token": "h", "backpack.password": "b"])
        let keychain = Keychain(items: items)
        #expect(keychain.get("jira.token") == "j")
        #expect(keychain.get("github.token") == "h")
        #expect(keychain.get("backpack.password") == "b")
        #expect(items.accounts == [Keychain.account])
        #expect(Keychain(items: items).get("gitlab.token") == "g")
    }

    /// The old items go only once the new one holds their secrets.
    @Test func theSeparateItemsStayWhenTheOneCannotBeWritten() {
        let items = FakeKeychainItems(["gitlab.token": "g"], refusesWrites: true)
        #expect(Keychain(items: items).get("gitlab.token") == "g")
        #expect(items.accounts == ["gitlab.token"])
    }

    /// A read the person denied is not an empty Keychain: writing then would replace every other
    /// secret with the one being saved.
    @Test func aRefusedReadIsNeverWrittenOver() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#], refusesReads: true)
        let keychain = Keychain(items: items)
        #expect(keychain.get("jira.token") == nil)
        #expect(!keychain.set("gitlab.token", "g"))
        items.refusesReads.withLock { $0 = false }
        #expect(Keychain(items: items).get("jira.token") == "j")
        #expect(Keychain(items: items).get("gitlab.token") == nil)
    }

    @Test func aRefusedWriteKeepsWhatWasThere() {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        keychain.set("jira.token", "j")
        items.refusesWrites.withLock { $0 = true }
        #expect(!keychain.set("jira.token", "other"))
        #expect(keychain.get("jira.token") == "j")
    }

    @Test func removingTheLastSecretRemovesTheItem() {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        keychain.set("jira.token", "j")
        #expect(keychain.set("jira.token", nil))
        #expect(keychain.get("jira.token") == nil)
        #expect(items.accounts.isEmpty)
    }
}

private final class FakeKeychainItems: KeychainItems {
    let values: Locked<[String: Data]>
    let reads = Locked(0)
    let refusesReads: Locked<Bool>
    let refusesWrites: Locked<Bool>

    init(_ values: [String: String] = [:], refusesReads: Bool = false, refusesWrites: Bool = false) {
        self.values = Locked(values.mapValues { Data($0.utf8) })
        self.refusesReads = Locked(refusesReads)
        self.refusesWrites = Locked(refusesWrites)
    }

    var accounts: [String] { values.withLock { $0.keys.sorted() } }

    func read(_ account: String) -> KeychainRead {
        reads.withLock { $0 += 1 }
        if refusesReads.withLock({ $0 }) { return .refused }
        return values.withLock { $0[account] }.map(KeychainRead.found) ?? .missing
    }

    func write(_ account: String, _ data: Data) -> Bool {
        if refusesWrites.withLock({ $0 }) { return false }
        values.withLock { $0[account] = data }
        return true
    }

    func delete(_ account: String) -> Bool {
        if refusesWrites.withLock({ $0 }) { return false }
        values.withLock { $0[account] = nil }
        return true
    }
}
