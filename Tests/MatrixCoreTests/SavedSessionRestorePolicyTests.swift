import Foundation
import MatrixCore
import Testing

private let sampleRecord = SavedSessionRecord(
    accountID: "@brandon:example.org",
    userID: "@brandon:example.org",
    homeserverURL: "https://example.org"
)

@Test
func offlineSavedSessionStartupBecomesUsableWithoutDeletingDurableData() {
    let plan = SavedSessionRestorePolicy.startupPlan(persistedSessions: [sampleRecord])

    #expect(!plan.immediateState.isBusy)
    #expect(plan.immediateState.showsWorkspace)
    #expect(plan.immediateState == .reconnecting(message: SavedSessionRestorePolicy.reconnectingMessage))
    #expect(plan.immediateState != .signedOut(message: "Saved session could not be restored."))
    #expect(plan.startBackgroundReconnect)
    #expect(plan.retainPersistedSessions)
    #expect(plan.summaries.map(\.userID) == ["@brandon:example.org"])
}

@Test
func emptyPersistedSessionsStaySignedOutAndDoNotReconnect() {
    let plan = SavedSessionRestorePolicy.startupPlan(persistedSessions: [])
    #expect(plan.immediateState == .signedOut(message: nil))
    #expect(!plan.startBackgroundReconnect)
    #expect(!plan.retainPersistedSessions)
    #expect(plan.summaries.isEmpty)
}

@Test
func unreachableHomeserverKeepsPersistedSessionAndRetries() {
    let outcome = SavedSessionRestorePolicy.outcomeAfterAttempt(
        pending: [sampleRecord],
        results: [sampleRecord.accountID: .failure(.unreachableHomeserver)],
        alreadyRestoredCount: 0,
        attempt: 0
    )

    #expect(outcome.removedAccountIDs.isEmpty)
    #expect(outcome.stillPendingAccountIDs == [sampleRecord.accountID])
    #expect(outcome.retainRemainingPersistedSessions)
    #expect(outcome.nextState.showsWorkspace)
    #expect(outcome.nextState.isBusy == false)
    #expect(outcome.retryDelay == 0)
}

@Test
func timedOutRestoreIsTransientAndDoesNotRemoveSession() {
    #expect(SavedSessionRestorePolicy.classify(SavedSessionRestoreFailure.timedOut) == .transient)
    #expect(SavedSessionRestorePolicy.classify(URLError(.cannotConnectToHost)) == .transient)
    #expect(!SavedSessionRestorePolicy.shouldRemovePersistedSession(for: URLError(.timedOut)))
}

@Test
func corruptOrUnauthorizedSessionsAreRemovedAndDoNotBlockSignIn() {
    let outcome = SavedSessionRestorePolicy.outcomeAfterAttempt(
        pending: [sampleRecord],
        results: [sampleRecord.accountID: .failure(.corruptSession)],
        alreadyRestoredCount: 0,
        attempt: 0
    )

    #expect(outcome.removedAccountIDs == [sampleRecord.accountID])
    #expect(outcome.stillPendingAccountIDs.isEmpty)
    #expect(outcome.nextState == .signedOut(message: "Saved session could not be restored."))
    #expect(!outcome.retainRemainingPersistedSessions)
    #expect(SavedSessionRestorePolicy.shouldRemovePersistedSession(for: SavedSessionRestoreFailure.unauthorized))
}

@Test
func successfulBackgroundRestoreMovesToConnected() {
    let outcome = SavedSessionRestorePolicy.outcomeAfterAttempt(
        pending: [sampleRecord],
        results: [sampleRecord.accountID: .success(())],
        alreadyRestoredCount: 0,
        attempt: 1
    )
    #expect(outcome.nextState == .connected)
    #expect(outcome.stillPendingAccountIDs.isEmpty)
    #expect(outcome.retryDelay == nil)
}

@Test
func genericRestoreErrorIsTransientAndKeepsDurableSession() {
    struct UnreachableHomeserver: Error {}
    #expect(SavedSessionRestorePolicy.classify(UnreachableHomeserver()) == .transient)
    #expect(!SavedSessionRestorePolicy.shouldRemovePersistedSession(for: UnreachableHomeserver()))
}

@Test
func oneRestoredAccountKeepsTransientSiblingsAndWorkspace() {
    let second = SavedSessionRecord(
        accountID: "@other:example.org",
        userID: "@other:example.org",
        homeserverURL: "https://example.org"
    )
    let outcome = SavedSessionRestorePolicy.outcomeAfterAttempt(
        pending: [sampleRecord, second],
        results: [
            sampleRecord.accountID: .success(()),
            second.accountID: .failure(.timedOut)
        ],
        alreadyRestoredCount: 0,
        attempt: 2
    )

    #expect(outcome.removedAccountIDs.isEmpty)
    #expect(outcome.stillPendingAccountIDs == [second.accountID])
    #expect(outcome.retainRemainingPersistedSessions)
    #expect(outcome.nextState.showsWorkspace)
    #expect(outcome.nextState.isBusy == false)
    #expect(outcome.retryDelay == 5)
}

@Test
func reconnectBackoffIsBounded() {
    let delays = (0..<12).map { SavedSessionRestorePolicy.retryDelay(attempt: $0) }
    #expect(delays[0] == 0)
    #expect(delays[1] == 2)
    #expect(delays[4] == 30)
    #expect(delays[11] == SavedSessionRestorePolicy.maxRetryDelay)
    #expect(delays.allSatisfy { $0 <= SavedSessionRestorePolicy.maxRetryDelay })
}
