// Ported from AiTerm (app/Sources/AiTermCore/Updates/ReleaseSource.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// One published version and the disk image that holds it.
public struct Release: Equatable, Sendable {
    public let version: ReleaseVersion
    public let assetURL: URL
    public init(version: ReleaseVersion, assetURL: URL) { self.version = version; self.assetURL = assetURL }
}

public extension Release {
    /// What a release's disk image is called.
    static func assetName(for version: ReleaseVersion) -> String { "Shellforge-\(version).dmg" }
}

/// Where releases come from: the only part of self-update that knows a hosting service. Shellforge
/// reads GitHub alone (AiTerm's GitLab source is not ported). Everything after `download` —
/// staging, verifying, installing — is the same for any source.
public protocol ReleaseSource: Sendable {
    func latest() async throws -> Release
    func download(_ release: Release, to destination: URL) async throws
}

/// The download: the request's body streamed to a temporary file, then moved to its place. The
/// image is the whole app bundle, so it never sits in memory.
enum ReleaseDownload {
    /// `mapping` turns the request's failure into the host's `UpdateError`. A file that is already
    /// at `destination` is replaced.
    static func save(_ request: URLRequest, to destination: URL, session: URLSession,
                     mapping: (HTTPJSON.Failure) -> UpdateError) async throws {
        let file: URL
        do { (file, _) = try await HTTPJSON.download(request, session: session) }
        catch let failure as HTTPJSON.Failure { throw mapping(failure) }
        let fm = FileManager.default
        defer { try? fm.removeItem(at: file) }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: file, to: destination)
        } catch {
            throw UpdateError.other(error.localizedDescription)
        }
    }
}

/// Every way a check or an update can stop, each with the one line the alert shows.
public enum UpdateError: Error, Equatable, LocalizedError {
    case noFeed, projectNotFound(CodeHost, String), noRelease(CodeHost)
    case unreachable(String), badResponse(CodeHost, Int), rateLimited
    case unreadableTag(CodeHost, String), missingAsset(CodeHost, String), unverified, translocated, cannotReplace(String), devBuild, installFailed(String), installAborted(Int32), other(String)

    public var message: String {
        switch self {
        case .noFeed: return "This build of Shellforge has no update source."
        case .projectNotFound(.gitHub, let path): return "GitHub has no repository at \(path)."
        case .projectNotFound(let host, let path): return "\(host.name) has no project at \(path)."
        case .noRelease(let host): return "\(host.name) has no Shellforge release yet."
        case .unreachable(let host): return "Couldn’t reach \(host)."
        case .badResponse(let host, let status): return "\(host.name) returned an error (HTTP \(status)). Try again."
        case .rateLimited: return "GitHub is limiting update checks from this network. Try again later."
        case .unreadableTag(let host, let tag): return "\(host.name)’s latest release, \(tag), has no version Shellforge understands."
        case .missingAsset(let host, let version):
            let asset = ReleaseVersion(version).map(Release.assetName(for:)) ?? "Shellforge-\(version).dmg"
            return "\(host.name)’s release \(version) has no \(asset)."
        case .unverified: return "The downloaded update couldn’t be verified. Nothing was changed."
        case .translocated: return "Move Shellforge to the Applications folder to get updates."
        case .cannotReplace(let folder): return "Shellforge can’t replace itself in \(folder): you don’t have permission to change it."
        case .devBuild: return "This is a development build, which doesn’t update. Open Shellforge from Applications to get updates."
        case .installFailed(let detail): return "Shellforge couldn’t start the update. \(detail)"
        case .installAborted(let status):
            switch status {
            case 1: return "The update wasn’t installed: Shellforge didn’t quit in time."
            case 2: return "The update wasn’t installed: the old version couldn’t be moved aside."
            case 3: return "The update wasn’t installed: the new version couldn’t be moved into place, so the old one was put back."
            default: return "The update wasn’t installed: the install helper stopped with status \(status)."
            }
        case .other(let text): return text
        }
    }

    public var errorDescription: String? { message }
}

/// One entry of a host's release list as a source read it: its tag, if it had one, and its assets
/// by file name.
struct ReleaseEntry {
    var tag: String?
    var assets: [String: URL]
}

/// How a source picks from a page of releases: the highest version on the page that has its disk
/// image. A stray tag that is not a version, or a release published before its image was attached,
/// must not hide every good release behind it. When nothing is installable the error names the
/// newest problem: the highest version's missing image, else the first tag that is no version.
/// `nil` is an entry that did not decode at all; a page on which none did is no release list, a
/// bad response.
enum ReleasePage {
    static func newest(_ page: [ReleaseEntry?], host: CodeHost, status: Int) throws -> Release {
        guard !page.isEmpty else { throw UpdateError.noRelease(host) }
        let list = page.compactMap { $0 }
        guard let first = list.first else { throw UpdateError.badResponse(host, status) }
        let versioned = list.compactMap { entry in entry.tag.flatMap(ReleaseVersion.init).map { ($0, entry) } }
        guard let highest = versioned.map(\.0).max() else { throw UpdateError.unreadableTag(host, first.tag ?? "") }
        let installable = versioned.compactMap { version, entry in
            entry.assets[Release.assetName(for: version)].map { Release(version: version, assetURL: $0) }
        }
        guard let newest = installable.max(by: { $0.version < $1.version }) else { throw UpdateError.missingAsset(host, highest.description) }
        return newest
    }
}
