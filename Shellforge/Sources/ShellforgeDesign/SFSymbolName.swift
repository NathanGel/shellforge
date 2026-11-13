import SwiftUI

/// Every SF Symbol the package draws, by name, so no view spells one as a string. The host's own
/// `SFSymbol` enum is in the iTerm2 target, which the package cannot see; this is the package's
/// counterpart, named apart from it so the host can import both. A new symbol is a new case here,
/// with its exact SF Symbols name as the raw value.
public enum SFSymbolName: String, CaseIterable, Sendable {
    case arrowTriangleBranch = "arrow.triangle.branch"
    case arrowUturnBackward = "arrow.uturn.backward"
    case asterisk
    case boltHorizontalCircle = "bolt.horizontal.circle"
    case bubbleLeft = "bubble.left"
    case checkmark
    case chevronDown = "chevron.down"
    case chevronLeftForwardslashChevronRight = "chevron.left.forwardslash.chevron.right"
    case chevronRight = "chevron.right"
    case circle
    case circleFill = "circle.fill"
    case circleSlash = "circle.slash"
    case doc
    case docText = "doc.text"
    case ellipsis
    case exclamationmark
    case exclamationmarkTriangleFill = "exclamationmark.triangle.fill"
    case folder
    case folderFill = "folder.fill"
    case gaugeWithDotsNeedle33Percent = "gauge.with.dots.needle.33percent"
    case gearshape
    case hexagon
    case infoCircleFill = "info.circle.fill"
    case iphone
    case keyboard
    case line3Horizontal = "line.3.horizontal"
    case macbook
    case minus
    case minusCircle = "minus.circle"
    case network
    case paintpalette
    case personalhotspot
    case pinFill = "pin.fill"
    case playFill = "play.fill"
    case plus
    case plusForwardslashMinus = "plus.forwardslash.minus"
    case rectangleStack = "rectangle.stack"
    case serverRack = "server.rack"
    case sidebarLeft = "sidebar.left"
    case sparkles
    case squareGrid2x2Fill = "square.grid.2x2.fill"
    case stopFill = "stop.fill"
    case terminal
    case ticket
    case triangleFill = "triangle.fill"
    case xmark
    case xmarkOctagonFill = "xmark.octagon.fill"
}

public extension Image {
    /// The SF Symbol `symbol`.
    init(symbol: SFSymbolName) {
        self.init(systemName: symbol.rawValue)
    }
}
