// Ported from AiTerm (app/Sources/AiTermCore/Backpack/LiveLidSensor.swift), GPLv3, Laurens D'Hondt.
import Foundation
import IOKit

/// The lid through `IOPMrootDomain`'s `AppleClamshellState`, which `ioreg` shows unprivileged. With
/// sleep disabled a closed lid no longer sleeps the Mac, so this is how the Backpack sheet notices it.
public struct IOKitLidSensor: LidSensor {
    public init() {}

    public func isClosed() -> Bool? {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return Self.parse(value)
    }

    /// A boolean, or nil: a desktop Mac has no such property.
    static func parse(_ value: CFTypeRef?) -> Bool? {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }
}
