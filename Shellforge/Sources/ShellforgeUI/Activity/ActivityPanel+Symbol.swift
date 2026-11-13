import ShellforgeCore
import ShellforgeDesign

/// A panel's icon in the activity bar. Here rather than beside the panel in ShellforgeCore, which
/// cannot see ShellforgeDesign's symbol names.
extension ActivityPanel {
    public var symbol: SFSymbolName {
        switch self {
        case .sessions: .rectangleStack
        case .metrics: .gaugeWithDotsNeedle33Percent
        case .files: .folder
        case .git: .arrowTriangleBranch
        case .ssh: .serverRack
        }
    }
}
