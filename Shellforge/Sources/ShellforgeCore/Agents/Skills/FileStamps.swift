// Ported from AiTerm (app/Sources/AiTermCore/Git/WatchedFileCache.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// A `State` for each key, every one behind a lock of its own. What a cache does for one key — run
/// git, which can take a deadline's worth of seconds — holds up nobody asking about another, and
/// two callers asking about the same key do the work once, the second waiting for the first.
final class KeyedStates<State: Sendable>: Sendable {
    private final class Slot: Sendable {
        let state: Locked<State>
        init(_ state: State) { self.state = Locked(state) }
    }

    private let initial: State
    private let slots = Locked<[String: Slot]>([:])

    init(_ initial: State) { self.initial = initial }

    /// `body` on `key`'s state, under that key's lock alone.
    func withState<Result>(for key: String, _ body: (inout State) throws -> Result) rethrows -> Result {
        let slot = slots.withLock { slots in
            if let slot = slots[key] { return slot }
            let slot = Slot(initial)
            slots[key] = slot
            return slot
        }
        return try slot.state.withLock { try body(&$0) }
    }

    /// Drops the state of every key not in `live`. A call still working on one finishes with it and
    /// nobody sees what it wrote.
    func retain(only live: Set<String>) {
        slots.withLock { slots in slots = slots.filter { live.contains($0.key) } }
    }
}

/// The ``WatchedFileCache`` check over several files at once, for an answer that depends on more
/// than one — a merge-base on both refs it joins. Each file is stamped in order, `nil` for one
/// that does not exist: a ref kept only in `packed-refs`, or a branch with no remote, is a state
/// like any other, and its file appearing is a change like any other.
struct FileStamps: Equatable {
    /// What a rewrite changes. The date alone misses a second rewrite within the same tick of a
    /// filesystem that keeps whole seconds; git writes a ref to a lock file and renames it into
    /// place, so the new file also has a new inode, and usually a new size.
    struct Stamp: Equatable { let modified: Date, inode: UInt64, size: UInt64 }

    let files: [String]
    private let stamps: [Stamp?]

    init(_ files: [String]) {
        self.files = files
        stamps = files.map(Self.stamp)
    }

    /// Stamps taken one at a time, each just before its file was read: for a walk that learns which
    /// files its answer depends on only as it reads them (`SkillCatalog`).
    init(files: [String], stamps: [Stamp?]) {
        self.files = files
        self.stamps = stamps
    }

    /// Whether every file is as it was when these stamps were taken.
    var areCurrent: Bool { self == FileStamps(files) }

    /// Whether not one of the files exists: the directory they are in is gone, or never was.
    var noneExist: Bool { stamps.allSatisfy { $0 == nil } }

    static func stamp(_ path: String) -> Stamp? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        return Stamp(modified: modified, inode: inode, size: size)
    }

    /// One line of a `rev-parse --git-path` answer, made absolute: git answers with an absolute
    /// path from inside a linked worktree and a relative one from an ordinary checkout.
    static func absolute(_ answer: String, in directory: String) -> String {
        answer.hasPrefix("/") ? answer : directory + "/" + answer
    }
}
