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
        #expect(Keychain(items: items).setData(bytes, service: "example.service", account: "example-account") == .written)
        #expect(Keychain(items: items).data(service: "example.service", account: "example-account") == .found(bytes))
        #expect(Keychain(items: items).setData(nil, service: "example.service", account: "example-account") == .written)
        #expect(Keychain(items: items).data(service: "example.service", account: "example-account") == .missing)
        #expect(items.accounts.isEmpty)
    }

    @Test func removingABinaryEntryKeepsTheOthers() {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        #expect(keychain.set("jira.token", "j"))
        #expect(keychain.setData(Data("a".utf8), service: "example.service", account: "one") == .written)
        #expect(keychain.setData(Data("b".utf8), service: "example.service", account: "two") == .written)
        #expect(keychain.setData(nil, service: "example.service", account: "one") == .written)
        let fresh = Keychain(items: items)
        #expect(fresh.get("jira.token") == "j")
        #expect(fresh.data(service: "example.service", account: "one") == .missing)
        #expect(fresh.data(service: "example.service", account: "two") == .found(Data("b".utf8)))
    }

    @Test func stringAndBinaryEntriesShareOneItem() throws {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        #expect(keychain.set("jira.token", "j"))
        #expect(keychain.setData(Data("x".utf8), service: "example.service", account: "example-account") == .written)
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
        #expect(keychain.setData(Data("x".utf8), service: "example.service", account: "example-account") == .unavailable)
        #expect(keychain.setData(nil, service: "example.service", account: "example-account") == .unavailable)
        #expect(items.writes.withLock { $0 } == 0)
        #expect(items.values.withLock { $0[Keychain.account] } == Data(original.utf8))
        // A refusal is not remembered: once access is granted, the same instance reads again.
        items.refusesReads.withLock { $0 = false }
        #expect(keychain.get("jira.token") == "j")
    }

    /// Readers that arrive while the first read is still waiting on the Keychain wait for it
    /// rather than each asking. The fake holds the first read open until the second reader is
    /// about to ask; a second read while the first is open answers at once and is recorded, so a
    /// broken lock fails the test rather than hanging it. A second reader that only arrives once
    /// the first read is done would pass either way; no test can rule that out without a hook in
    /// the lock itself.
    @Test func concurrentReadersReadOnce() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let started = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let open = Locked(false)
        let overlapped = Locked(false)
        items.onRead.withLock {
            $0 = {
                let alreadyOpen = open.withLock { isOpen in
                    defer { isOpen = true }
                    return isOpen
                }
                if alreadyOpen {
                    overlapped.withLock { $0 = true }
                    return
                }
                started.signal()
                gate.wait()
                open.withLock { $0 = false }
            }
        }
        let keychain = Keychain(items: items)
        let results = Locked<[String?]>([])
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            let value = keychain.get("jira.token")
            results.withLock { $0.append(value) }
        }
        started.wait()
        DispatchQueue.global().async(group: group) {
            secondEntered.signal()
            let value = keychain.get("jira.token")
            results.withLock { $0.append(value) }
        }
        secondEntered.wait()
        gate.signal()
        group.wait()
        #expect(!overlapped.withLock { $0 })
        #expect(results.withLock { $0 } == ["j", "j"])
        #expect(items.reads.withLock { $0 } == 1)
    }

    // MARK: Writes from other processes, read-backs and moves

    /// Two processes share the item. The second one's entries survive the first one's write,
    /// although the first read the item before they were there.
    @Test func aSecondProcessesEntriesSurviveAWrite() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let first = Keychain(items: items)
        let second = Keychain(items: items)
        first.warm()
        #expect(second.set("x", "1"))
        #expect(first.set("y", "2"))
        let fresh = Keychain(items: items)
        #expect(fresh.get("jira.token") == "j")
        #expect(fresh.get("x") == "1")
        #expect(fresh.get("y") == "2")
    }

    /// The stamp shows no prompt, so a write with no other writer reads the item only once.
    @Test func aWriteWithNoOtherWriterDoesNotReadAgain() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let keychain = Keychain(items: items)
        #expect(keychain.set("x", "1"))
        #expect(keychain.set("y", "2"))
        #expect(items.reads.withLock { $0 } == 1)
    }

    @Test func confirmStoredReadsTheItemNotTheCache() throws {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        let bytes = Data("invented".utf8)
        #expect(keychain.setData(bytes, service: "example.service", account: "example-account") == .written)
        #expect(keychain.confirmStored(bytes, service: "example.service", account: "example-account"))
        items.values.withLock { $0[Keychain.account] = Data(#"{"jira.token":"j"}"#.utf8) }
        let before = items.reads.withLock { $0 }
        #expect(!keychain.confirmStored(bytes, service: "example.service", account: "example-account"))
        #expect(items.reads.withLock { $0 } == before + 1)
        #expect(keychain.data(service: "example.service", account: "example-account") == .found(bytes), "the cache is left alone")
    }

    @Test func setDataIfMissingNeverOverwrites() {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        let newer = Data("newer".utf8)
        #expect(keychain.setData(newer, service: "example.service", account: "example-account") == .written)
        #expect(keychain.setDataIfMissing(Data("older".utf8), service: "example.service", account: "example-account", reapPending: true) == .present(newer))
        #expect(!keychain.reapPending(service: "example.service", account: "example-account"))
        #expect(Keychain(items: items).data(service: "example.service", account: "example-account") == .found(newer))
    }

    /// The move and its pending reap land in one write; a later write clears the mark.
    @Test func aMoveMarksItsReapUntilCleared() {
        let items = FakeKeychainItems()
        let keychain = Keychain(items: items)
        let bytes = Data("moved".utf8)
        #expect(keychain.setDataIfMissing(bytes, service: "example.service", account: "example-account", reapPending: true) == .inserted)
        #expect(items.writes.withLock { $0 } == 1)
        #expect(Keychain(items: items).reapPending(service: "example.service", account: "example-account"))
        #expect(keychain.clearReapPending(service: "example.service", account: "example-account") == .written)
        #expect(!Keychain(items: items).reapPending(service: "example.service", account: "example-account"))
        #expect(keychain.setDataIfMissing(Data("other".utf8), service: "example.service", account: "other", reapPending: true) == .inserted)
        #expect(keychain.setData(Data("newer".utf8), service: "example.service", account: "other") == .written)
        #expect(!Keychain(items: items).reapPending(service: "example.service", account: "other"))
    }

    @Test func aFailedWriteSaysWhy() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let keychain = Keychain(items: items)
        items.refusesWrites.withLock { $0 = true }
        #expect(keychain.setData(Data("x".utf8), service: "example.service", account: "example-account") == .failed)
        #expect(keychain.data(service: "example.service", account: "example-account") == .missing)
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
    /// Bumped by every write and delete; the stamp's date, as the Keychain's modification date would.
    private let version = Locked(0)

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

    func stamp(_ account: String) -> KeychainStamp? {
        guard values.withLock({ $0[account] }) != nil else { return .absent }
        return KeychainStamp(modified: Date(timeIntervalSinceReferenceDate: Double(version.withLock { $0 })), writeID: nil)
    }

    func write(_ account: String, _ data: Data) -> Bool {
        writes.withLock { $0 += 1 }
        if refusesWrites.withLock({ $0 }) { return false }
        values.withLock { $0[account] = data }
        version.withLock { $0 += 1 }
        return true
    }

    func delete(_ account: String) -> Bool {
        writes.withLock { $0 += 1 }
        if refusesWrites.withLock({ $0 }) { return false }
        values.withLock { $0[account] = nil }
        version.withLock { $0 += 1 }
        return true
    }
}
