import Foundation

enum ClassicSyncWatchdogPolicy {
    static func restartReason(
        handleFinished: Bool,
        secondsSinceLastResponse: TimeInterval?,
        staleAfter: TimeInterval
    ) -> String? {
        if handleFinished {
            return "task-finished"
        }
        guard let secondsSinceLastResponse else {
            return "no-response-recorded"
        }
        if secondsSinceLastResponse >= staleAfter {
            return "response-timeout"
        }
        return nil
    }
}
