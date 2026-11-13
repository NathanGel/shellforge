import Foundation

/// A `UserDefaults` whose values live in this object alone: a write is read back at once, by this
/// process only, with no cfprefsd, file or other process in between. For a test whose verdict
/// rests on reading back what it wrote. What it doesn't override falls through to a scratch suite
/// (`ScratchDefaults`), so nothing ever reaches the developer's defaults.
public final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public static func make() -> MemoryDefaults {
        guard let defaults = MemoryDefaults(suiteName: ScratchDefaults.suiteName()) else {
            preconditionFailure("a scratch suite name is always a valid suite")
        }
        return defaults
    }

    public override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    public override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    public override func removeObject(forKey defaultName: String) {
        set(nil, forKey: defaultName)
    }

    public override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    public override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    public override func bool(forKey defaultName: String) -> Bool {
        (object(forKey: defaultName) as? Bool) ?? false
    }

    public override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { values }
    }
}
