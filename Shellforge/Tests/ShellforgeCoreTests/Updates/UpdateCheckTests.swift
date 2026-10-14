// Ported from AiTerm (app/Tests/AiTermCoreTests/UpdateCheckTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

private struct FixedSource: ReleaseSource {
    let result: Result<Release, UpdateError>
    func latest() async throws -> Release { try result.get() }
    func download(_ release: Release, to destination: URL) async throws {}
}

private struct StrangeError: Error, LocalizedError { var errorDescription: String? { "Something odd." } }
private struct ThrowingSource: ReleaseSource {
    func latest() async throws -> Release { throw StrangeError() }
    func download(_ release: Release, to destination: URL) async throws {}
}

@Suite struct UpdateCheckTests {
    let url = URL(string: "https://github.com/octocat/hello/releases/download/v0.3.0/Shellforge-0.3.0.dmg")!
    func release(_ v: String) -> Release { Release(version: ReleaseVersion(v)!, assetURL: url) }
    let current = ReleaseVersion("0.2.0")!

    @Test func newerReleaseIsAvailable() async {
        let r = release("0.3.0")
        #expect(await UpdateCheck.run(source: FixedSource(result: .success(r)), current: current) == .available(r))
    }

    @Test func sameReleaseIsCurrent() async {
        #expect(await UpdateCheck.run(source: FixedSource(result: .success(release("0.2.0"))), current: current) == .current(current))
    }

    /// A build ahead of the newest release is not offered a downgrade.
    @Test func olderReleaseIsCurrent() async {
        #expect(await UpdateCheck.run(source: FixedSource(result: .success(release("0.1.9"))), current: current) == .current(current))
    }

    @Test func sourceErrorsPassThrough() async {
        #expect(await UpdateCheck.run(source: FixedSource(result: .failure(.rateLimited)), current: current) == .failed(.rateLimited))
    }

    @Test func foreignErrorsBecomeOther() async {
        #expect(await UpdateCheck.run(source: ThrowingSource(), current: current) == .failed(.other("Something odd.")))
    }

    @Test func everyErrorHasItsExactLine() {
        #expect(UpdateError.noRelease(.gitHub).message == "GitHub has no Shellforge release yet.")
        #expect(UpdateError.projectNotFound(.gitHub, "octocat/hello").message == "GitHub has no repository at octocat/hello.")
        #expect(UpdateError.unreachable("api.github.com").message == "Couldn’t reach api.github.com.")
        #expect(UpdateError.unverified.message == "The downloaded update couldn’t be verified. Nothing was changed.")
        #expect(UpdateError.translocated.message == "Move Shellforge to the Applications folder to get updates.")
        #expect(UpdateError.noFeed.message == "This build of Shellforge has no update source.")
        #expect(UpdateError.badResponse(.gitHub, 502).message == "GitHub returned an error (HTTP 502). Try again.")
        #expect(UpdateError.unreadableTag(.gitHub, "nightly").message == "GitHub’s latest release, nightly, has no version Shellforge understands.")
        #expect(UpdateError.missingAsset(.gitHub, "0.3.0").message == "GitHub’s release 0.3.0 has no Shellforge-0.3.0.dmg.")
        #expect(UpdateError.rateLimited.message == "GitHub is limiting update checks from this network. Try again later.")
        #expect(UpdateError.devBuild.message == "This is a development build, which doesn’t update. Open Shellforge from Applications to get updates.")
        #expect(UpdateError.installFailed("Permission denied.").message == "Shellforge couldn’t start the update. Permission denied.")
        #expect(UpdateError.installAborted(1).message == "The update wasn’t installed: Shellforge didn’t quit in time.")
        #expect(UpdateError.other("Something odd.").message == "Something odd.")
        #expect(UpdateError.rateLimited.errorDescription == UpdateError.rateLimited.message)
    }
}
