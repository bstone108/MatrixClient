import Diagnostics
import Foundation
@testable import MatrixCore
import Persistence
import Testing

private actor FlakyTransport: SendQueueTransport {
    private var attempts = 0

    func reconcile(message: QueuedMessage) async throws -> SendReconciliationResult {
        .missing
    }

    func send(message: QueuedMessage) async throws -> SendAttemptResult {
        attempts += 1
        if attempts == 1 {
            throw SendTransportFailure.transient("network down")
        }
        return .accepted(eventID: "$ok")
    }
}

private actor FetchOrderRecorder {
    private var values: [SDKMediaFetchPriority] = []

    func append(_ value: SDKMediaFetchPriority) {
        values.append(value)
    }

    func snapshot() -> [SDKMediaFetchPriority] {
        values
    }
}

@Test
func reliableSendQueueRetriesTransientErrorsWithoutPermanentFailure() async throws {
    let diagnostics = DiagnosticsService(subsystem: "test.queue")
    let database = try AppDatabase(inMemory: diagnostics)
    let repository = QueuedMessageRepository(database: database, diagnostics: diagnostics)
    let transport = FlakyTransport()
    let queue = ReliableSendQueue(repository: repository, diagnostics: diagnostics, transport: transport)

    await queue.enqueue(
        accountID: AccountIdentifier(rawValue: "acct-test"),
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        body: "Retry me",
        transactionID: EventTransactionIdentifier(rawValue: "txn-retry")
    )

    try await Task.sleep(for: .seconds(1))

    let snapshot = await queue.snapshot()
    #expect(snapshot.count == 1)
    #expect(snapshot.first?.state == .accepted)
    #expect(snapshot.first?.eventID == "$ok")
}

@Test
func mediaDownloadPolicyLimitsBackgroundWorkWhileActiveRoomIsBusy() {
    let decision = MediaDownloadSchedulingPolicy.immediateLane(
        for: "!other:test",
        activeRoomID: "!active:test",
        pendingRoomIDs: ["!active:test"],
        runningRoomIDs: ["!active:test", "!other-running:test"]
    )

    #expect(decision == nil)
}

@Test
func mediaDownloadPolicyLetsBackgroundBorrowAllLanesWhenActiveRoomIsIdle() {
    let first = MediaDownloadSchedulingPolicy.immediateLane(
        for: "!other:test",
        activeRoomID: "!active:test",
        pendingRoomIDs: [],
        runningRoomIDs: []
    )
    let second = MediaDownloadSchedulingPolicy.immediateLane(
        for: "!other:test",
        activeRoomID: "!active:test",
        pendingRoomIDs: [],
        runningRoomIDs: ["!other:test", "!else:test"]
    )

    #expect(first == .background)
    #expect(second == .background)
}

@Test
func mediaDownloadPolicyPrioritizesNewActiveRoomAfterSwitch() {
    let firstDecision = MediaDownloadSchedulingPolicy.nextPendingDecision(
        activeRoomID: "!new-active:test",
        pendingRoomIDs: ["!new-active:test", "!new-active:test", "!old-active:test"],
        runningRoomIDs: ["!old-active:test", "!old-active:test"]
    )
    let secondDecision = MediaDownloadSchedulingPolicy.nextPendingDecision(
        activeRoomID: "!new-active:test",
        pendingRoomIDs: ["!new-active:test", "!old-active:test"],
        runningRoomIDs: ["!old-active:test", "!new-active:test"]
    )

    #expect(firstDecision == MediaDownloadSchedulingDecision(pendingIndex: 0, lane: .activeRoom))
    #expect(secondDecision == MediaDownloadSchedulingDecision(pendingIndex: 0, lane: .activeRoom))
}

@Test
func thumbnailDownloadPolicyReservesWorkersForActiveRoomBacklog() {
    let decision = MediaDownloadSchedulingPolicy.nextPendingDecision(
        activeRoomID: "!active:test",
        pendingRoomIDs: ["!active:test", "!other:test"],
        runningRoomIDs: ["!active:test"],
        policy: .thumbnails
    )

    #expect(decision == MediaDownloadSchedulingDecision(pendingIndex: 0, lane: .activeRoom))
}

@Test
func thumbnailDownloadPolicyLetsBackgroundBorrowWhenActiveRoomHasNoBacklog() {
    let decision = MediaDownloadSchedulingPolicy.nextPendingDecision(
        activeRoomID: "!active:test",
        pendingRoomIDs: ["!other:test"],
        runningRoomIDs: ["!active:test"],
        policy: .thumbnails
    )

    #expect(decision == MediaDownloadSchedulingDecision(pendingIndex: 0, lane: .background))
}

@Test
func mediaBackoffSkipsItemUntilDeadlineWithoutChangingItsEligibilityLater() {
    let now = Date(timeIntervalSince1970: 1_000)
    let deadline = now.addingTimeInterval(5)
    let requeued = MediaDownloadBackoffPolicy.movingToBottom("failed", in: ["failed", "next", "last"])

    #expect(requeued == ["next", "last", "failed"])
    #expect(!MediaDownloadBackoffPolicy.isEligible(eligibleAt: deadline, now: now))
    #expect(MediaDownloadBackoffPolicy.isEligible(eligibleAt: deadline, now: deadline))
    #expect(MediaDownloadBackoffPolicy.eligibleQueueIndices(
        eligibleAt: [deadline, now, now],
        now: now
    ) == [1, 2])
    #expect(MediaDownloadBackoffPolicy.eligibleQueueIndices(
        eligibleAt: [deadline, now, now],
        now: deadline
    ) == [0, 1, 2])
    #expect(MediaDownloadBackoffPolicy.retryDelay(afterFailedAttempt: 1) == 5)
    #expect(MediaDownloadBackoffPolicy.retryDelay(afterFailedAttempt: 2) == 15)
}

@Test
func hardMediaTimeoutDoesNotWaitForUnderlyingOperation() async {
    let clock = ContinuousClock()
    let start = clock.now
    var didTimeOut = false

    do {
        let _: Int = try await withHardThrowingTimeout(.milliseconds(20)) {
            try await Task.sleep(for: .milliseconds(250))
            return 1
        }
    } catch is MediaFetchTimeoutError {
        didTimeOut = true
    } catch {
        Issue.record("Unexpected timeout error: \(error)")
    }

    #expect(didTimeOut)
    #expect(start.duration(to: clock.now) < .milliseconds(150))
}

@Test
func originalRegularReservedPolicyKeepsBackgroundOutWhileActiveRoomIsBusy() {
    let decision = MediaDownloadSchedulingPolicy.nextPendingDecision(
        activeRoomID: "!active:test",
        pendingRoomIDs: ["!other:test"],
        runningRoomIDs: ["!active:test"],
        policy: .originalRegularReserved
    )

    #expect(decision == nil)
}

@Test
func originalHelperPolicyStillLetsBackgroundBorrowWhenRecoveryLaneIsFree() {
    let decision = MediaDownloadSchedulingPolicy.nextPendingDecision(
        activeRoomID: "!active:test",
        pendingRoomIDs: ["!other:test"],
        runningRoomIDs: ["!active:test", "!active:test"],
        policy: .originals
    )

    #expect(decision == MediaDownloadSchedulingDecision(pendingIndex: 0, lane: .background))
}

@Test
func mediaCandidateURLsStayPinnedToHomeserverOrigin() {
    let homeserver = URL(string: "https://matrix.example.com")!
    let urls = MatrixMediaCache.mediaCandidateURLs(
        serverName: "evil.example.net",
        mediaID: "abc123",
        homeserverURL: homeserver
    )

    #expect(urls.count == 3)
    #expect(urls.allSatisfy { $0.host == "matrix.example.com" })
    #expect(urls.allSatisfy { $0.query == nil })
}

@Test
func sanitizedHomeserverBaseURLDropsCredentialsAndQuery() {
    let sanitized = MatrixMediaCache.sanitizedHomeserverBaseURL(
        from: "https://user:secret@matrix.example.com/base/path?sid=123&access_token=456#frag"
    )

    #expect(sanitized?.absoluteString == "https://matrix.example.com")
}

@Test
func sdkMediaFetchGatePrioritizesThumbnailsBeforeAvatarsAndOriginals() async throws {
    let gate = SDKMediaFetchGateCoordinator()
    let recorder = FetchOrderRecorder()

    async let occupyingFetch: Void = gate.withExclusiveFetch(scopeID: "scope", priority: .original) {
        try await Task.sleep(for: .milliseconds(100))
    }

    try await Task.sleep(for: .milliseconds(10))

    async let originalFetch: Void = gate.withExclusiveFetch(scopeID: "scope", priority: .original) {
        await recorder.append(.original)
    }
    async let avatarFetch: Void = gate.withExclusiveFetch(scopeID: "scope", priority: .avatar) {
        await recorder.append(.avatar)
    }
    async let thumbnailFetch: Void = gate.withExclusiveFetch(scopeID: "scope", priority: .thumbnail) {
        await recorder.append(.thumbnail)
    }

    _ = try await occupyingFetch
    _ = try await originalFetch
    _ = try await avatarFetch
    _ = try await thumbnailFetch

    let snapshot = await recorder.snapshot()
    #expect(snapshot == [.thumbnail, .avatar, .original])
}
