// Ported from AiTerm (app/Tests/AiTermCoreTests/Support/DriverTestSupport.swift), GPLv3, Laurens D'Hondt.
import Foundation
@testable import ShellforgeCore

extension HookDriver {
    /// What the probe reads.
    var state: HookState { probe().state }
}
