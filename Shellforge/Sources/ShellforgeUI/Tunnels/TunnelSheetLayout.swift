import Foundation

/// What the Tunnels and SSH Host sheets share, so their host lists line up: the alias column's
/// width, a sheet geometry rather than a design token (`Metrics.swift` stays AiTerm's).
enum TunnelSheetLayout {
    static let aliasColumnWidth: CGFloat = 120
}
