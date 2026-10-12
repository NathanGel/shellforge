// Ported from AiTerm (app/Sources/AiTerm/ActionUnavailable.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// Why an action cannot go ahead, in words the person can act on — "Connect Jira in Settings…".
/// Thrown by the app's workflows and the creation sheets' searches alike, and shown as is.
/// Its description is the message too, for the reports that interpolate the error they caught.
public struct ActionUnavailable: LocalizedError, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}
