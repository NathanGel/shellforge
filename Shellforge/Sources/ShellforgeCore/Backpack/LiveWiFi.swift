// Ported from AiTerm (app/Sources/AiTermCore/Backpack/LiveWiFi.swift), GPLv3, Laurens D'Hondt.
import Foundation
import CoreWLAN

/// The Mac's Wi-Fi through CoreWLAN, which names networks only while Shellforge has Location access.
/// The known-network list comes from `networksetup`, which macOS does not redact.
public struct CoreWLANWiFi: WiFiControl {
    /// How long a join may take to show up as the current network.
    static let joinWait: TimeInterval = 15

    public init() {}

    private var interface: CWInterface? { CWWiFiClient.shared().interface() }

    public func knownNetworks() -> [String] {
        guard let name = interface?.interfaceName,
              let output = BackpackLog.attempt("Listing the preferred Wi-Fi networks", {
                  try BackpackProcess.run(URL(fileURLWithPath: "/usr/sbin/networksetup"),
                                        ["-listpreferredwirelessnetworks", name], timeout: 10)
              }),
              output.status == 0 else { return [] }
        return Self.parsePreferred(output.stdout)
    }

    /// `networksetup -listpreferredwirelessnetworks`: a heading, then one tab-indented name per line.
    /// Only the tab is stripped: a network's name may begin or end with spaces.
    static func parsePreferred(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("\t") }
            .map { String($0.dropFirst()) }
            .filter { !$0.isEmpty }
    }

    public func currentNetwork() -> String? { interface?.ssid() }

    public func isInRange(_ network: String) -> Bool {
        !scan(network).isEmpty
    }

    /// One scan for every network in range; a scan straight after another fails with `EBUSY`, so it is tried once more.
    public func networksInRange() -> Set<String> {
        guard let interface else { return [] }
        let found = (try? interface.scanForNetworks(withName: nil))
            ?? { Thread.sleep(forTimeInterval: 1)
                 return BackpackLog.attempt("Scanning for Wi-Fi networks", level: .info) { try interface.scanForNetworks(withName: nil) } ?? []
               }()
        return Set(found.compactMap(\.ssid))
    }

    /// A scan straight after another fails with `EBUSY`, so a failed one is tried once more.
    private func scan(_ network: String) -> Set<CWNetwork> {
        guard let interface else { return [] }
        if let found = try? interface.scanForNetworks(withName: network) { return found }
        Thread.sleep(forTimeInterval: 1)
        return BackpackLog.attempt("Scanning for \(network)", level: .info) { try interface.scanForNetworks(withName: network) } ?? []
    }

    /// CoreWLAN first, then `networksetup`, which the spike saw join an iPhone hotspot when given
    /// its password. Either way, joined means the interface reports the network within `joinWait`.
    /// `networksetup` takes the password as an argument, visible to this user's `ps` for the moment
    /// it runs; it is only reached when CoreWLAN fails.
    public func join(_ network: String, password: String?) -> Bool {
        guard let interface else { return false }
        if let target = scan(network).first,
           BackpackLog.attempt("Joining \(network) through CoreWLAN", level: .info, { try interface.associate(to: target, password: password) }) != nil,
           waitUntilJoined(network) { return true }
        guard let name = interface.interfaceName,
              let output = BackpackLog.attempt("Joining \(network) through networksetup", {
                  try BackpackProcess.run(URL(fileURLWithPath: "/usr/sbin/networksetup"),
                                        ["-setairportnetwork", name, network] + (password.map { [$0] } ?? []), timeout: 30)
              }),
              output.status == 0 else { return false }
        // networksetup prints "Failed to join…" and still exits 0.
        let said = (output.stdout + output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard said.isEmpty else { return false }
        return waitUntilJoined(network)
    }

    private func waitUntilJoined(_ network: String) -> Bool {
        let deadline = Date().addingTimeInterval(Self.joinWait)
        while Date() < deadline {
            if currentNetwork() == network { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }
}
