import Foundation
import MachO

/// Which of its two looks AppKit draws in this process. AppKit picks by the SDK the *executable* was
/// linked against, not by the SDK the tests were compiled with: linked against the macOS 26 SDK or
/// later it draws the current design, the one the app ships with (Xcode builds it against that SDK);
/// against an older one, or with `UIDesignRequiresCompatibility` in its Info.plist, it draws the
/// compatibility look. Under `scripts/swift.sh test` the host is swiftly's `swiftpm-testing-helper`,
/// linked against the macOS 14 SDK; under Xcode's `swift test` it is Xcode's, linked against the
/// current SDK. Tests that compare against what macOS draws natively expect each look's own values.
public enum AppKitLook: Sendable {
    case compatibility
    case current

    public static let drawn: AppKitLook = {
        if Bundle.main.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility") as? Bool == true {
            return .compatibility
        }
        guard let sdk = linkedSDKMajor() else { return .current }
        return sdk >= 26 ? .current : .compatibility
    }()

    /// The major version of the SDK the main executable was linked against, from its
    /// `LC_BUILD_VERSION` load command.
    private static func linkedSDKMajor() -> UInt32? {
        guard let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 else { return nil }
        var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let command = cursor.loadUnaligned(as: load_command.self)
            if command.cmd == UInt32(LC_BUILD_VERSION) {
                return cursor.loadUnaligned(as: build_version_command.self).sdk >> 16
            }
            cursor = cursor.advanced(by: Int(command.cmdsize))
        }
        return nil
    }
}
