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

    // MARK: Binary entries (iTerm2’s upgrade-safe secrets kept in the same item)

    @Test func binaryEntriesRoundTrip() {
        let items = FakeKeychainItems()
        let bytes = Data([0x00, 0xFF, 0x10, 0x80, 0x7F])
        #expect(Keychain(items: items).data(service: "example.service", account: "example-account") == .missing)
        #expect(Keychain(items: items).setData(bytes, service: "example.service", account: "example-account"))
        #expect(Keychain(items: items).data(service: "example.service", account: "example-account") == .found(bytes))
        #expect(Keychain(items: items).setData(nil, service: "example.service", account: "example-account"))
        #expect(Keychain(items: items).data(service: "example.service", account: "example-account") == .missing)
        #expect(items.accounts.isEmpty)
    }

    @Test func stringAndBinaryEntriesShareOneItem() throws {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        #expect(keychain.set("jira.token", "j"))
        #expect(keychain.setData(Data("x".utf8), service: "example.service", account: "example-account"))
        #expect(items.accounts == [Keychain.account])
        let stored = try #require(items.values.withLock { $0[Keychain.account] })
        let json = try JSONDecoder().decode([String: String].self, from: stored)
        #expect(json == ["jira.token": "j", "upgradeSafe:example.service:example-account": Data("x".utf8).base64EncodedString()])

        let fresh = Keychain(items: items)
        items.reads.withLock { $0 = 0 }
        #expect(fresh.get("jira.token") == "j")
        #expect(fresh.data(service: "example.service", account: "example-account") == .found(Data("x".utf8)))
        #expect(items.reads.withLock { $0 } == 1)
    }

    /// A denied read is not an empty vault: answering `missing` would invite a caller to write
    /// over everything the item holds.
    @Test func aRefusedVaultReadWritesNothing() {
        let original = #"{"jira.token":"j"}"#
        let items = FakeKeychainItems([Keychain.account: original], refusesReads: true)
        let keychain = Keychain(items: items)
        #expect(keychain.data(service: "example.service", account: "example-account") == .unavailable)
        #expect(!keychain.setData(Data("x".utf8), service: "example.service", account: "example-account"))
        #expect(!keychain.setData(nil, service: "example.service", account: "example-account"))
        #expect(items.writes.withLock { $0 } == 0)
        #expect(items.values.withLock { $0[Keychain.account] } == Data(original.utf8))
        // A refusal is not remembered: once access is granted, the same instance reads again.
        items.refusesReads.withLock { $0 = false }
        #expect(keychain.get("jira.token") == "j")
    }

    /// Readers that arrive while the first read is still waiting on the Keychain wait for it
    /// rather than each asking. The fake holds the first read open until both readers are running.
    @Test func concurrentReadersReadOnce() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        items.onRead.withLock { $0 = { started.signal(); gate.wait() } }
        let keychain = Keychain(items: items)
        let results = Locked<[String?]>([])
        let group = DispatchGroup()
        for _ in 0..<2 {
            DispatchQueue.global().async(group: group) {
                let value = keychain.get("jira.token")
                results.withLock { $0.append(value) }
            }
        }
        started.wait()
        items.onRead.withLock { $0 = nil }
        gate.signal()
        group.wait()
        #expect(results.withLock { $0 } == ["j", "j"])
        #expect(items.reads.withLock { $0 } == 1)
    }

    @Test func warmReadsOnce() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let keychain = Keychain(items: items)
        keychain.warm()
        #expect(items.reads.withLock { $0 } == 1)
        keychain.warm()
        #expect(keychain.get("jira.token") == "j")
        #expect(keychain.data(service: "example.service", account: "example-account") == .missing)
        #expect(items.reads.withLock { $0 } == 1)
    }
}

private final class FakeKeychainItems: KeychainItems {
    let values: Locked<[String: Data]>
    let reads = Locked(0)
    /// Writes and deletes alike: either changes what the Keychain holds.
    let writes = Locked(0)
    /// Runs inside `read`, before it answers, so a test can hold a read open.
    let onRead = Locked<(@Sendable () -> Void)?>(nil)
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
        onRead.withLock { $0 }?()
        if refusesReads.withLock({ $0 }) { return .refused }
        return values.withLock { $0[account] }.map(KeychainRead.found) ?? .missing
    }

    func write(_ account: String, _ data: Data) -> Bool {
        writes.withLock { $0 += 1 }
        if refusesWrites.withLock({ $0 }) { return false }
        values.withLock { $0[account] = data }
        return true
    }

    func delete(_ account: String) -> Bool {
        writes.withLock { $0 += 1 }
        if refusesWrites.withLock({ $0 }) { return false }
        values.withLock { $0[account] = nil }
        return true
    }
}
