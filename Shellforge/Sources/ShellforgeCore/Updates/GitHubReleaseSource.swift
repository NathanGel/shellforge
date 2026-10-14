// Ported from AiTerm (app/Sources/AiTermCore/Updates/GitHubReleaseSource.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Releases of one public GitHub repository, read without a token: Shellforge's repository is
/// public, so an update check needs no credential and sends none — not even the token Settings
/// saved for reviews. Drafts and prereleases are never offered. The image is the asset's
/// `browser_download_url`, which GitHub redirects to its CDN.
public struct GitHubReleaseSource: ReleaseSource {
    public let owner: String, repo: String
    let session: URLSession

    public init(owner: String, repo: String, session: URLSession = .shared) {
        self.owner = owner; self.repo = repo; self.session = session
    }

    public func latest() async throws -> Release {
        guard let url = HTTPJSON.url("https://api.github.com/repos/\(owner)/\(repo)/releases", query: [URLQueryItem(name: "per_page", value: "20")])
        else { throw UpdateError.projectNotFound(.gitHub, "\(owner)/\(repo)") }
        let (page, status) = try await HTTPJSON.decode([Lenient<ReleasePayload>].self, request(url, timeout: 15), session: session) {
            mapped($0, listing: true)
        }
        let published = page.filter { $0.value.map { !$0.isDraft && !$0.isPrerelease } ?? true }
        return try ReleasePage.newest(published.map { $0.value?.entry }, host: .gitHub, status: status)
    }

    /// Streamed to disk, not held in memory: the image is the whole app bundle.
    public func download(_ release: Release, to destination: URL) async throws {
        try await ReleaseDownload.save(request(release.assetURL, timeout: 300), to: destination, session: session) {
            mapped($0, listing: false)
        }
    }

    private func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        HTTPJSON.request(url, headers: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"], timeout: timeout)
    }

    /// Unauthenticated, GitHub answers a spent rate limit with 403 or 429. A 404 for the release
    /// list is the repository; for an image it is only a bad link. A listing that is no release
    /// list at all is a bad response, whatever its status.
    private func mapped(_ failure: HTTPJSON.Failure, listing: Bool) -> UpdateError {
        switch failure {
        case .transport: return .unreachable("api.github.com")
        case .status(403), .status(429): return .rateLimited
        case .status(404) where listing: return .projectNotFound(.gitHub, "\(owner)/\(repo)")
        case .status(let status), .undecodable(let status): return .badResponse(.gitHub, status)
        }
    }
}

/// The fields of one entry of GitHub's release list that an update needs.
private struct ReleasePayload: Decodable {
    struct Asset: Decodable { var name: String?, browserDownloadUrl: String? }
    var tagName: String?, draft: Bool?, prerelease: Bool?, assets: [Lenient<Asset>]?

    var isDraft: Bool { draft ?? false }
    var isPrerelease: Bool { prerelease ?? false }

    var entry: ReleaseEntry {
        let named = (assets ?? []).compactMap(\.value).compactMap { asset in
            asset.name.flatMap { name in asset.browserDownloadUrl.flatMap(URL.init(string:)).map { (name, $0) } }
        }
        return ReleaseEntry(tag: tagName, assets: Dictionary(named, uniquingKeysWith: { first, _ in first }))
    }
}
