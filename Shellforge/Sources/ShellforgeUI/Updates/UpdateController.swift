// Ported from AiTerm (app/Sources/AiTerm/UpdateController.swift), GPLv3, Laurens D'Hondt.
import AppKit
import Foundation
import ShellforgeCore

/// What **Check for Updates…** does: ask the release source, say "latest" or offer the newer version,
/// and on **Update** download, verify, hand over to the install helper and quit. Every side effect is
/// injected, so tests drive the whole flow through a scripted prompter; `live(prompter:)` wires the
/// real ones. Nothing here runs unless someone chooses the menu item.
@MainActor
public final class UpdateController {
    private let prompter: Prompter
    private let currentVersion: String?
    private let channel: BuildChannel
    private let bundleURL: URL
    private let updatesDirectory: URL
    private let makeSource: () throws -> any ReleaseSource
    private let checkReplaceable: () throws -> Void
    private let stage: @Sendable (URL, ReleaseVersion) throws -> URL
    private let install: (URL) throws -> Void
    private let terminate: () -> Void
    private let showProgress: (String) -> () -> Void

    /// True from the menu choice until its last alert closes; the menu item is disabled meanwhile.
    /// Once the install helper is armed it stays true: if the quit is cancelled, that helper still
    /// waits for this process, and a second Update would restage under it and race it.
    public private(set) var isBusy = false

    init(prompter: Prompter, currentVersion: String?, channel: BuildChannel = .release, bundleURL: URL, updatesDirectory: URL,
         makeSource: @escaping () throws -> any ReleaseSource,
         checkReplaceable: @escaping () throws -> Void,
         stage: @escaping @Sendable (URL, ReleaseVersion) throws -> URL,
         install: @escaping (URL) throws -> Void,
         terminate: @escaping () -> Void,
         showProgress: @escaping (String) -> () -> Void) {
        self.prompter = prompter; self.currentVersion = currentVersion; self.channel = channel
        self.bundleURL = bundleURL
        self.updatesDirectory = updatesDirectory; self.makeSource = makeSource; self.checkReplaceable = checkReplaceable
        self.stage = stage
        self.install = install; self.terminate = terminate; self.showProgress = showProgress
    }

    public func checkForUpdates() async {
        guard !isBusy else { return }
        isBusy = true
        var handedOff = false
        defer { if !handedOff { isBusy = false } }
        // A dev build's ad-hoc signature could never verify a release, and replacing a build
        // folder's bundle with a release would lose what was being tried out, so it never asks.
        // A version that is no release's (iTerm2's `unknown`, `3.7.dev`) is a build the release
        // script did not stamp: a dev build too, never offered a release over it.
        guard channel == .release, let current = currentVersion.flatMap(ReleaseVersion.init) else {
            return await report(UpdateError.devBuild)
        }
        // A translocated copy is read-only, so no helper could replace it.
        if BundleLocation.isTranslocated(bundleURL.path) { return await report(UpdateError.translocated) }
        let source: any ReleaseSource
        do { source = try makeSource() } catch { return await report(error) }

        switch await UpdateCheck.run(source: source, current: current) {
        case .current(let version):
            _ = await prompter.ask(AlertPrompt(message: "You’re on the latest version (\(version))."))
        case .failed(let error):
            await report(error)
        case .available(let release):
            let answer = await prompter.ask(AlertPrompt(message: "Shellforge \(release.version) is available.", buttons: ["Update", "Later"], escape: 1))
            guard answer.confirmed else { return }
            handedOff = await update(to: release, from: source)
        }
    }

    /// True once the install helper is running and the app has been asked to quit.
    private func update(to release: Release, from source: any ReleaseSource) async -> Bool {
        do { try checkReplaceable() } catch { await report(error); return false }
        let image = updatesDirectory.appendingPathComponent(Release.assetName(for: release.version))
        let staged: URL
        do {
            let dismiss = showProgress("Downloading Shellforge \(release.version)…")
            defer { dismiss(); try? FileManager.default.removeItem(at: image) }
            try await source.download(release, to: image)
            // `hdiutil`, `ditto` and `codesign` block for seconds, which the cooperative pool must not.
            let stage = self.stage
            staged = try await BackgroundWork.run { try stage(image, release.version) }
        } catch {
            await report(error)
            return false
        }
        do { try install(staged) } catch { await report(error); return false }
        terminate()
        return true
    }

    /// On launch: say why the last update didn't install, if it didn't, then clear `Updates/` —
    /// the replaced app, the helper and its result are only needed until the next version runs.
    /// The result is taken before the alert is up, so the alert cannot come twice.
    public func finishPreviousUpdate() async {
        let status = UpdateInstaller.takePreviousResult(in: updatesDirectory)
        UpdateInstaller.removeLeftovers(in: updatesDirectory)
        if let status, status != 0 {
            _ = await prompter.ask(AlertPrompt(message: Self.message(for: UpdateError.installAborted(status))))
        }
    }

    private func report(_ error: Error) async {
        _ = await prompter.ask(AlertPrompt(message: Self.message(for: error)))
    }

    private static func message(for error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }
}

extension UpdateController {
    /// The real wiring: the running bundle's version, feed, build channel and signature, the
    /// updates folder in Caches, and `NSApp.terminate` — whose normal quit path saves state first.
    public static func live(prompter: Prompter, bundle: Bundle = .main) -> UpdateController {
        let bundleURL = bundle.bundleURL, identifier = bundle.bundleIdentifier ?? ""
        let feed = bundle.object(forInfoDictionaryKey: ReleaseFeed.infoKey) as? String
        let updates = updatesDirectory(identifier: identifier)
        return UpdateController(
            prompter: prompter,
            currentVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            channel: BuildChannel(infoDictionary: bundle.infoDictionary),
            bundleURL: bundleURL, updatesDirectory: updates,
            makeSource: { try ReleaseFeed.source(for: feed) },
            checkReplaceable: { try UpdateInstaller.checkReplaceable(bundleURL) },
            stage: { image, version in
                let requirement = try UpdateStager.designatedRequirement(of: bundleURL)
                return try UpdateStager(expectedIdentifier: identifier, requirement: requirement).stage(dmg: image, version: version, in: updates)
            },
            install: { staged in
                try UpdateInstaller.launch(staged: staged, installed: bundleURL, updates: updates,
                                           pid: ProcessInfo.processInfo.processIdentifier)
            },
            terminate: { NSApp.terminate(nil) },
            showProgress: UpdateProgressPanel.show)
    }

    /// `~/Library/Caches/<bundle id>/Updates`: the image, the staged app, the helper and the
    /// replaced app, cleared on the launch after an update.
    static func updatesDirectory(identifier: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(identifier.isEmpty ? "io.github.nathangel.shellforge" : identifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }
}
