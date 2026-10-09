// Ported from AiTerm (app/Sources/AiTermCore/Hooks/BundleLocation.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Where macOS is running the app from, which is not always where it lives.
///
/// Gatekeeper path randomisation ("App Translocation") mounts a quarantined bundle — one copied or
/// downloaded and opened without being moved in Finder — under a random
/// `/private/var/folders/…/T/AppTranslocation/<UUID>/d/` path, read-only, and throws that mount
/// away when the app quits. Anything the app persists about its own location is therefore dead the
/// moment it closes, which is how a user's `settings.json` ended up naming a status-line
/// command that exits 127 forever.
public enum BundleLocation {
    /// Matched on the path rather than through `SecTranslocateIsTranslocatedURL`, so the rule is
    /// testable without a translocated bundle to hand. Best effort by design: if Apple ever moves
    /// the mount point this stops warning, and `ClaudeSettings.statusLineIsInstalled` still
    /// reports the broken feed, because it checks whether the command can actually be run.
    public static func isTranslocated(_ path: String) -> Bool { path.contains("/AppTranslocation/") }

    public static let translocationWarning = "macOS is running Shellforge from a temporary copy, so its agent hooks cannot be installed. Move Shellforge to /Applications in Finder and reopen it."
}
