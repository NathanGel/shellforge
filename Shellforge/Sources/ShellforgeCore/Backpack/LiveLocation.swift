// Ported from AiTerm (app/Sources/AiTermCore/Backpack/LiveLocation.swift), GPLv3, Laurens D'Hondt.
import Foundation
import CoreLocation

/// Location access, which macOS requires before CoreWLAN names a network. Shellforge never asks for a
/// location; it only needs the grant. On the main actor: `CLLocationManager` reports to the thread
/// that made it.
///
/// A new `CLLocationManager` reads `notDetermined` until its delegate hears the real status (the
/// spike saw it), so this keeps one manager for the app's life and caches what it reports.
@MainActor
public final class CoreLocationAccess: NSObject, LocationAccess, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private nonisolated let status = Locked(CLAuthorizationStatus.notDetermined)
    private var waiting: CheckedContinuation<Bool, Never>?

    public override init() {
        super.init()
        manager.delegate = self
    }

    nonisolated public func isAuthorized() -> Bool {
        Self.granted(status.withLock { $0 })
    }

    /// macOS answers `requestWhenInUseAuthorization` only while the status is undetermined; once
    /// it is answered, asking again prompts nothing and calls no delegate.
    nonisolated static func canAsk(_ status: CLAuthorizationStatus) -> Bool { status == .notDetermined }

    public func request() async -> Bool {
        let current = manager.authorizationStatus
        status.withLock { $0 = current }
        guard Self.canAsk(current) else { return Self.granted(current) }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Called as the delegate is set, with the status as it stands, and again with each answer.
    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let current = manager.authorizationStatus
        status.withLock { $0 = current }
        guard current != .notDetermined else { return }
        MainActor.assumeIsolated {
            waiting?.resume(returning: Self.granted(current))
            waiting = nil
        }
    }

    /// macOS has one granted status: a when-in-use request is answered `authorizedAlways` (3),
    /// which is what the spike saw.
    nonisolated private static func granted(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways
    }
}

extension BackpackPorts {
    /// The real ports: `sudo pmset`, CoreWLAN, IOKit, CoreLocation and the admin prompt.
    @MainActor public static func live() -> BackpackPorts {
        BackpackPorts(lidSleep: SudoLidSleep(), wifi: CoreWLANWiFi(), power: IOKitPowerSource(),
                      location: CoreLocationAccess(), installer: AdminPromptInstaller(),
                      lidSensor: IOKitLidSensor())
    }
}
