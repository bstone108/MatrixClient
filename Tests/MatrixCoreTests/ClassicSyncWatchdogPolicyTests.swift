@testable import MatrixCore
import Testing

@Test
func classicSyncWatchdogRestartsFinishedTask() {
    #expect(ClassicSyncWatchdogPolicy.restartReason(
        handleFinished: true,
        secondsSinceLastResponse: 1,
        staleAfter: 75
    ) == "task-finished")
}

@Test
func classicSyncWatchdogRestartsSilentRunningTask() {
    #expect(ClassicSyncWatchdogPolicy.restartReason(
        handleFinished: false,
        secondsSinceLastResponse: 76,
        staleAfter: 75
    ) == "response-timeout")
}

@Test
func classicSyncWatchdogLeavesHealthyTaskRunning() {
    #expect(ClassicSyncWatchdogPolicy.restartReason(
        handleFinished: false,
        secondsSinceLastResponse: 30,
        staleAfter: 75
    ) == nil)
}
