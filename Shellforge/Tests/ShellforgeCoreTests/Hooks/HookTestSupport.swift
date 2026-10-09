// Ported from AiTerm (app/Tests/AiTermCoreTests/Support/DriverTestSupport.swift), GPLv3, Laurens D'Hondt.
import Foundation
@testable import ShellforgeCore

extension HookDriver {
    /// What the probe reads.
    var state: HookState { probe().state }
}

extension GrokHooksFile {
    /// The hooks file's own state, whatever the status line says.
    static func state(home: URL, port: Int) -> HookState {
        switch UserConfigFile(home: home, path).read() {
        case .missing: return .missing
        case .refused: return .unreadable
        case .present(let data): return state(of: data, port: port)
        }
    }
}
