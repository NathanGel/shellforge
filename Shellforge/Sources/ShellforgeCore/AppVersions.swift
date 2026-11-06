import Foundation

/// The two version strings Shellforge puts on a report: its own and macOS's.
public struct AppVersions: Equatable, Sendable {
    public let version: String
    public let macOS: String

    public init(version: String, macOS: String) {
        self.version = version
        self.macOS = macOS
    }

    public init(infoDictionary: [String: Any]?, os: OperatingSystemVersion) {
        self.init(version: infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                  macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
    }

    public static var current: AppVersions {
        AppVersions(infoDictionary: Bundle.main.infoDictionary,
                    os: ProcessInfo.processInfo.operatingSystemVersion)
    }
}
