import Foundation
import os

/// What the ported Backpack ports call AiTerm's `ProcessRunner.run` for: a child process with the
/// app's own environment, through Shellforge's one `ChildProcess`. No timeout is AiTerm's "wait as
/// long as it takes" (the admin prompt waits for a person), here a day.
enum BackpackProcess {
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval? = nil) throws -> ChildOutput {
        try ChildProcess.run(executable.path, arguments, environment: ProcessInfo.processInfo.environment,
                             timeout: timeout ?? 86_400)
    }
}

/// AiTerm's `Log.backpack.attempt`: runs `work`, and logs its failure in one line instead of
/// throwing it.
enum BackpackLog {
    static let logger = Logger(subsystem: "io.github.nathangel.shellforge", category: "backpack")

    @discardableResult
    static func attempt<Value>(_ what: @autoclosure () -> String, level: OSLogType = .error,
                               _ work: () throws -> Value) -> Value? {
        do { return try work() } catch {
            let description = what()
            logger.log(level: level, "\(description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
