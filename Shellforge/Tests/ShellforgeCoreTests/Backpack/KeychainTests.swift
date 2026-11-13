// Ported from AiTerm (app/Tests/AiTermCoreTests/KeychainTests.swift), GPLv3, Laurens D'Hondt.
import Testing
import Foundation
@testable import ShellforgeCore
@testable import ShellforgeTestSupport

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

    // MARK: Two processes writing at once

    /// An older build, which takes no lock, read the item before this process wrote and stores its
    /// whole copy right after. The read-back sees its stamp, so this change is applied again on top
    /// of what it stored, and nothing is cached under its stamp: the next write keeps its entry too.
    @Test func aStaleStampIsNotCached() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let keychain = Keychain(items: items)
        keychain.warm()
        items.anotherWriterAfterWrites.withLock { $0 = [#"{"jira.token":"j","x":"1"}"#] }
        #expect(keychain.set("y", "2"))
        #expect(keychain.set("z", "3"))
        let fresh = Keychain(items: items)
        #expect(fresh.get("jira.token") == "j")
        #expect(fresh.get("x") == "1")
        #expect(fresh.get("y") == "2")
        #expect(fresh.get("z") == "3")
    }

    /// A writer that loses to another one every time gives up after the retries rather than looping.
    @Test func aWriteThatKeepsLosingGivesUp() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let keychain = Keychain(items: items)
        items.anotherWriterAfterWrites.withLock { $0 = Array(repeating: #"{"jira.token":"j"}"#, count: 10) }
        #expect(!keychain.set("y", "2"))
        #expect(items.writes.withLock { $0 } == 1 + Keychain.retries)
    }

    /// Another process holds the vault lock (`lockf` takes the same `flock`) and writes the item while
    /// this one waits for it. This process's write waits, then goes on top, so both entries are kept.
    @Test func twoWritersBothKeepTheirEntries() throws {
        let other = try #require(OtherProcessHoldingTheLock())
        defer { other.release() }
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let waiting = DispatchSemaphore(value: 0)
        // A bound far past the test's own, so a slow machine never ends the wait early.
        let keychain = Keychain(items: items, lock: VaultLock(url: other.lockURL, timeout: 600, waiting: { waiting.signal() }))
        keychain.warm()
        let result = Locked<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let written = keychain.set("y", "2")
            result.withLock { $0 = written }
            done.signal()
        }
        // Bounds for a broken lock only: a working one signals at once.
        let waited = waiting.wait(timeout: .now() + 60) == .success
        #expect(waited, "the writer did not wait for the other process's lock")
        #expect(items.writes.withLock { $0 } == 0)
        items.storeAsAnotherWriter(#"{"jira.token":"j","x":"1"}"#)
        other.release()
        try #require(done.wait(timeout: .now() + 60) == .success, "the writer never finished")

        #expect(result.withLock { $0 } == true)
        let fresh = Keychain(items: items)
        #expect(fresh.get("jira.token") == "j")
        #expect(fresh.get("x") == "1")
        #expect(fresh.get("y") == "2")
    }

    /// A process that keeps the lock (a prompt left open, a debugger stop) holds this one up only
    /// for the bound; then the write goes ahead without it, and the read-back still guards it.
    @Test func aLockHeldTooLongIsWaitedForOnlyUpToTheBound() throws {
        let other = try #require(OtherProcessHoldingTheLock())
        defer { other.release() }
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let waiting = Locked(false)
        let keychain = Keychain(items: items, lock: VaultLock(url: other.lockURL, timeout: 0.2, waiting: { waiting.withLock { $0 = true } }))
        let result = Locked<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let written = keychain.set("y", "2")
            result.withLock { $0 = written }
            done.signal()
        }
        // The other process never lets go before this returns; a bound for a broken wait only.
        try #require(done.wait(timeout: .now() + 60) == .success, "the writer waited past its bound")
        #expect(waiting.withLock { $0 })
        #expect(result.withLock { $0 } == true)
        #expect(Keychain(items: items).get("y") == "2")
    }

    /// After a wait ran out, the next writes for a while try the lock once and go ahead without it,
    /// rather than each waiting the whole bound again while every Keychain call here waits on them.
    @Test func aWaitThatRanOutIsNotRepeatedForAWhile() throws {
        let other = try #require(OtherProcessHoldingTheLock())
        defer { other.release() }
        let waits = Locked(0)
        let clock = Locked(Date(timeIntervalSince1970: 1_000_000))
        let lock = VaultLock(url: other.lockURL, timeout: 0.2, waiting: { waits.withLock { $0 += 1 } },
                             now: { clock.withLock { $0 } })
        #expect(lock.withLock { 1 } == 1)
        #expect(waits.withLock { $0 } == 1)
        clock.withLock { $0 += VaultLock.quietPeriod - 1 }
        #expect(lock.withLock { 2 } == 2)
        #expect(lock.withLock { 3 } == 3)
        #expect(waits.withLock { $0 } == 1, "no wait within the quiet period")
        clock.withLock { $0 += 2 }
        #expect(lock.withLock { 4 } == 4)
        #expect(waits.withLock { $0 } == 2, "past it, the bound is waited again")
    }

    /// A write that first moves the earlier items takes the lock once: every read after the first
    /// (which may prompt, so it comes before) is made under it, with no gap between the move and
    /// the change.
    @Test func aWriteThatMovesTheEarlierItemsTakesTheLockOnce() throws {
        let lockURL = TestScratch.root.appendingPathComponent("vault-\(UUID().uuidString).lock")
        try FileManager.default.createDirectory(at: TestScratch.root, withIntermediateDirectories: true)
        let items = FakeKeychainItems(["jira.token": "j"])
        let freeAtReads = Locked<[Bool]>([])
        items.onRead.withLock {
            $0 = { freeAtReads.withLock { $0.append(Self.isFree(lockURL)) } }
        }
        let keychain = Keychain(items: items, lock: VaultLock(url: lockURL, timeout: 600))
        #expect(keychain.set("y", "2"))
        let reads = freeAtReads.withLock { $0 }
        #expect(reads.first == true && reads.count >= 3 && !reads.dropFirst().contains(true), "got \(reads)")
        #expect(Keychain(items: items).get("jira.token") == "j")
        #expect(Keychain(items: items).get("y") == "2")
    }

    /// The first read may show a Keychain prompt, so it happens before the lock is taken.
    @Test func theFirstReadComesBeforeTheLock() throws {
        let lockURL = TestScratch.root.appendingPathComponent("vault-\(UUID().uuidString).lock")
        try FileManager.default.createDirectory(at: TestScratch.root, withIntermediateDirectories: true)
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        let freeAtReads = Locked<[Bool]>([])
        items.onRead.withLock {
            $0 = { freeAtReads.withLock { $0.append(Self.isFree(lockURL)) } }
        }
        let keychain = Keychain(items: items, lock: VaultLock(url: lockURL, timeout: 600))
        #expect(keychain.set("y", "2"))
        #expect(freeAtReads.withLock { $0 } == [true])
    }

    /// The earlier items are moved into the one item under the lock, like any other write.
    @Test func movingTheEarlierItemsTakesTheLock() throws {
        let other = try #require(OtherProcessHoldingTheLock())
        defer { other.release() }
        let items = FakeKeychainItems(["jira.token": "j"])
        let waiting = DispatchSemaphore(value: 0)
        let keychain = Keychain(items: items, lock: VaultLock(url: other.lockURL, timeout: 600, waiting: { waiting.signal() }))
        let read = Locked<String?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let value = keychain.get("jira.token")
            read.withLock { $0 = value }
            done.signal()
        }
        let waited = waiting.wait(timeout: .now() + 60) == .success
        #expect(waited, "the move did not wait for the other process's lock")
        #expect(items.writes.withLock { $0 } == 0)
        other.release()
        try #require(done.wait(timeout: .now() + 60) == .success, "the move never finished")
        #expect(read.withLock { $0 } == "j")
        #expect(items.accounts == [Keychain.account])
    }

    /// A stamp that cannot be read after a write is unknown, not another writer: one read of the
    /// value confirms the write instead of writing again.
    @Test func anUnreadableStampAfterAWriteIsConfirmedByOneRead() {
        let items = FakeKeychainItems([Keychain.account: #"{"jira.token":"j"}"#])
        items.unreadableStamps.withLock { $0 = true }
        let keychain = Keychain(items: items)
        #expect(keychain.set("y", "2"))
        #expect(items.writes.withLock { $0 } == 1)
        #expect(Keychain(items: items).get("y") == "2")
    }

    /// Whether no one holds the lock, asked from a descriptor of its own (`flock` locks belong to
    /// an open file, so this process's own hold counts too).
    private static func isFree(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
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

/// Another process, `lockf`, holding the vault lock on a scratch file until `release`.
private final class OtherProcessHoldingTheLock {
    let lockURL = TestScratch.root.appendingPathComponent("vault-\(UUID().uuidString).lock")
    private let process = Process()
    private let input = Pipe()
    private var released = false

    /// `nil` when `lockf` did not report holding the lock within a minute.
    init?() {
        try? FileManager.default.createDirectory(at: TestScratch.root, withIntermediateDirectories: true)
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
        process.arguments = ["-k", lockURL.path, "/bin/sh", "-c", "echo locked; read line"]
        process.standardInput = input
        process.standardOutput = output
        do { try process.run() } catch { return nil }
        // The shell runs only once `lockf` holds the lock. Read off this thread, so a `lockf` that
        // never says so fails the test rather than hanging it.
        let said = Locked("")
        let heard = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let data = output.fileHandleForReading.availableData
            said.withLock { $0 = String(decoding: data, as: UTF8.self) }
            heard.signal()
        }
        guard heard.wait(timeout: .now() + 60) == .success, said.withLock({ $0 }).hasPrefix("locked") else {
            release()
            return nil
        }
    }

    /// Ends the shell's `read`, so `lockf` exits and lets go.
    func release() {
        guard !released else { return }
        released = true
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
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
    /// Each payload is stored by another writer right after one of this process's writes, one
    /// payload per write, as a process that takes no lock would.
    let anotherWriterAfterWrites = Locked<[String]>([])
    /// Every stamp is `nil`, as when the item's attributes cannot be read.
    let unreadableStamps = Locked(false)
    /// Bumped by every write and delete; the stamp's date, as the Keychain's modification date would.
    private let version = Locked(0)
    private let writeIDs = Locked<[String: Data]>([:])

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
        if unreadableStamps.withLock({ $0 }) { return nil }
        guard values.withLock({ $0[account] }) != nil else { return .absent }
        return KeychainStamp(modified: Date(timeIntervalSinceReferenceDate: Double(version.withLock { $0 })),
                             writeID: writeIDs.withLock { $0[account] })
    }

    func write(_ account: String, _ data: Data, writeID: Data) -> Bool {
        writes.withLock { $0 += 1 }
        if refusesWrites.withLock({ $0 }) { return false }
        store(account, data, writeID: writeID)
        let next = anotherWriterAfterWrites.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        if let next { storeAsAnotherWriter(next) }
        return true
    }

    /// Another process's write: not counted in `writes`, with a write ID of its own.
    func storeAsAnotherWriter(_ json: String) {
        store(Keychain.account, Data(json.utf8), writeID: Data(UUID().uuidString.utf8))
    }

    private func store(_ account: String, _ data: Data, writeID: Data) {
        values.withLock { $0[account] = data }
        writeIDs.withLock { $0[account] = writeID }
        version.withLock { $0 += 1 }
    }

    func delete(_ account: String) -> Bool {
        writes.withLock { $0 += 1 }
        if refusesWrites.withLock({ $0 }) { return false }
        values.withLock { $0[account] = nil }
        writeIDs.withLock { $0[account] = nil }
        version.withLock { $0 += 1 }
        return true
    }
}
