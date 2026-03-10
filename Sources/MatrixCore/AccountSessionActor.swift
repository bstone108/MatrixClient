import Diagnostics
import Foundation
import Persistence

#if canImport(MatrixRustSDK)
@preconcurrency import MatrixRustSDK
#endif

#if canImport(MatrixRustSDK)
private final class RoomListEntriesListenerProxy: RoomListEntriesListener {
    private let handler: @Sendable ([RoomListEntriesUpdate]) -> Void

    init(handler: @escaping @Sendable ([RoomListEntriesUpdate]) -> Void) {
        self.handler = handler
    }

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        handler(roomEntriesUpdate)
    }
}

private final class RoomInfoListenerProxy: RoomInfoListener {
    private let handler: @Sendable () -> Void

    init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    func call(roomInfo _: RoomInfo) {
        handler()
    }
}

private final class RoomListServiceSyncIndicatorListenerProxy: RoomListServiceSyncIndicatorListener {
    private let handler: @Sendable (RoomListServiceSyncIndicator) -> Void

    init(handler: @escaping @Sendable (RoomListServiceSyncIndicator) -> Void) {
        self.handler = handler
    }

    func onUpdate(syncIndicator: RoomListServiceSyncIndicator) {
        handler(syncIndicator)
    }
}

private final class TimelineListenerProxy: TimelineListener {
    private let handler: @Sendable ([MatrixRustSDK.TimelineDiff]) -> Void

    init(handler: @escaping @Sendable ([MatrixRustSDK.TimelineDiff]) -> Void) {
        self.handler = handler
    }

    func onUpdate(diff: [MatrixRustSDK.TimelineDiff]) {
        handler(diff)
    }
}

private final class VerificationStateListenerProxy: VerificationStateListener {
    private let handler: @Sendable (VerificationState) -> Void

    init(handler: @escaping @Sendable (VerificationState) -> Void) {
        self.handler = handler
    }

    func onUpdate(status: VerificationState) {
        handler(status)
    }
}

private final class VerificationControllerDelegateProxy: SessionVerificationControllerDelegate {
    private let onAccept: @Sendable () async -> Void
    private let onStartSas: @Sendable () async -> Void
    private let onData: @Sendable (SessionVerificationData) async -> Void
    private let onFail: @Sendable () async -> Void
    private let onCancel: @Sendable () async -> Void
    private let onFinish: @Sendable () async -> Void

    init(
        onAccept: @escaping @Sendable () async -> Void,
        onStartSas: @escaping @Sendable () async -> Void,
        onData: @escaping @Sendable (SessionVerificationData) async -> Void,
        onFail: @escaping @Sendable () async -> Void,
        onCancel: @escaping @Sendable () async -> Void,
        onFinish: @escaping @Sendable () async -> Void
    ) {
        self.onAccept = onAccept
        self.onStartSas = onStartSas
        self.onData = onData
        self.onFail = onFail
        self.onCancel = onCancel
        self.onFinish = onFinish
    }

    func didAcceptVerificationRequest() {
        let onAccept = self.onAccept
        Task { await onAccept() }
    }

    func didStartSasVerification() {
        let onStartSas = self.onStartSas
        Task { await onStartSas() }
    }

    func didReceiveVerificationData(data: SessionVerificationData) {
        let onData = self.onData
        Task { await onData(data) }
    }

    func didFail() {
        let onFail = self.onFail
        Task { await onFail() }
    }

    func didCancel() {
        let onCancel = self.onCancel
        Task { await onCancel() }
    }

    func didFinish() {
        let onFinish = self.onFinish
        Task { await onFinish() }
    }
}

private final class TimelineSubscription: @unchecked Sendable {
    let room: Room
    let timeline: Timeline
    let listener: TimelineListenerProxy
    let handle: TaskHandle

    init(room: Room, timeline: Timeline, listener: TimelineListenerProxy, handle: TaskHandle) {
        self.room = room
        self.timeline = timeline
        self.listener = listener
        self.handle = handle
    }
}

private final class RoomInfoSubscription: @unchecked Sendable {
    let room: Room
    let listener: RoomInfoListenerProxy
    let handle: TaskHandle

    init(room: Room, listener: RoomInfoListenerProxy, handle: TaskHandle) {
        self.room = room
        self.listener = listener
        self.handle = handle
    }
}

private enum LiveMatrixSessionError: LocalizedError {
    case passwordLoginUnsupported
    case unsupportedSlidingSync
    case roomUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .passwordLoginUnsupported:
            return "This homeserver does not allow password login."
        case .unsupportedSlidingSync:
            return "This homeserver does not advertise native Sliding Sync."
        case let .roomUnavailable(roomID):
            return "The room \(roomID) is not currently available in Sliding Sync."
        }
    }
}

private struct RoomMemberProfile: Sendable {
    let displayName: String
    let avatarURL: String?
}

private struct ReadMarkerOverride: Sendable {
    let eventID: String
    let appliedAt: Date
}

public actor AccountSessionActor {
    private enum Constants {
        static let backgroundSweepInterval: Duration = .seconds(30)
        static let backgroundRoomTimelineLimit = 500
        static let activeRoomTimelineLimit = 500
        static let backgroundSubscriptionBatchSize = 64
        static let mediaRetentionMessageLimit = 500
    }

    public let summary: AccountSummary

    private let diagnostics: DiagnosticsService
    private let client: Client
    private let slidingSync = SlidingSyncCoordinator(spaces: [], rooms: [])
    private let timelineStore = TimelineStore()
    private let mediaCache: MatrixMediaCache
    private let receiptAvatarCache: ReceiptAvatarCache
    private let timelineRepository: PersistedTimelineRepository
    private let roomSummaryRepository: PersistedRoomSummaryRepository
    private let verificationBroadcaster = AsyncBroadcaster<VerificationSnapshot>()

    private var syncService: SyncService?
    private var roomListService: RoomListService?
    private var roomList: RoomList?
    private var roomListListener: RoomListEntriesListenerProxy?
    private var roomListHandle: TaskHandle?
    private var roomListSyncIndicatorListener: RoomListServiceSyncIndicatorListenerProxy?
    private var roomListSyncIndicatorHandle: TaskHandle?
    private var roomItems: [RoomListItem] = []
    private var roomItemsByID: [RoomIdentifier: RoomListItem] = [:]
    private var timelineSubscriptions: [RoomIdentifier: TimelineSubscription] = [:]
    private var roomInfoSubscriptions: [RoomIdentifier: RoomInfoSubscription] = [:]
    private var rawTimelineItemsByRoom: [RoomIdentifier: [TimelineItem]] = [:]
    private var roomMemberProfilesByRoom: [RoomIdentifier: [String: RoomMemberProfile]] = [:]
    private var roomDetailsCache: [RoomIdentifier: RoomDetails] = [:]
    private var backgroundSubscribedRoomIDs: Set<RoomIdentifier> = []
    private var restoredTimelineRoomIDs: Set<RoomIdentifier> = []
    private var lastMarkedReadEventIDByRoom: [RoomIdentifier: String] = [:]
    private var readMarkerOverridesByRoom: [RoomIdentifier: ReadMarkerOverride] = [:]
    private var backgroundRoomSweepTask: Task<Void, Never>?
    private var verificationController: SessionVerificationController?
    private var verificationControllerDelegate: VerificationControllerDelegateProxy?
    private var verificationStateListener: VerificationStateListenerProxy?
    private var verificationStateHandle: TaskHandle?
    private var verificationSnapshot: VerificationSnapshot
    private var bootstrapped = false

    private init(summary: AccountSummary, client: Client, diagnostics: DiagnosticsService, cacheRootURL: URL, database: AppDatabase) {
        self.summary = summary
        self.client = client
        self.diagnostics = diagnostics
        self.mediaCache = MatrixMediaCache(
            client: client,
            diagnostics: diagnostics,
            cacheRootURL: cacheRootURL
        )
        self.receiptAvatarCache = ReceiptAvatarCache(
            client: client,
            diagnostics: diagnostics,
            cacheRootURL: cacheRootURL
        )
        self.timelineRepository = PersistedTimelineRepository(
            database: database,
            diagnostics: diagnostics,
            accountID: summary.accountID.rawValue
        )
        self.roomSummaryRepository = PersistedRoomSummaryRepository(
            database: database,
            diagnostics: diagnostics,
            accountID: summary.accountID.rawValue
        )
        self.verificationSnapshot = VerificationSnapshot(
            state: .unknown,
            flow: .idle,
            deviceID: try? client.deviceId(),
            message: "This session is not verified yet."
        )
        verificationBroadcaster.yield(verificationSnapshot)
    }

    static func login(
        serverNameOrURL: String,
        username: String,
        password: String,
        sessionStore: StoredSessionStore,
        applicationSupportURL: URL,
        database: AppDatabase,
        diagnostics: DiagnosticsService
    ) async throws -> AccountSessionActor {
        let storeKey = sessionStore.storeKey(serverNameOrURL: serverNameOrURL, username: username)
        let paths = try sessionStore.accountStorePaths(for: storeKey)

        let builder = ClientBuilder()
            .serverNameOrHomeserverUrl(serverNameOrUrl: serverNameOrURL)
            .sessionPaths(dataPath: paths.dataPath, cachePath: paths.cachePath)
            .setSessionDelegate(sessionDelegate: sessionStore)
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .userAgent(userAgent: "MatrixClient/0.1")

        let client = try await builder.build()
        let loginDetails = await client.homeserverLoginDetails()
        guard loginDetails.slidingSyncVersion() == .native else {
            throw LiveMatrixSessionError.unsupportedSlidingSync
        }
        guard loginDetails.supportsPasswordLogin() else {
            throw LiveMatrixSessionError.passwordLoginUnsupported
        }

        try await client.login(
            username: username,
            password: password,
            initialDeviceName: Host.current().localizedName ?? "Matrix Client",
            deviceId: nil
        )

        let session = try client.session()
        _ = try sessionStore.save(session: session, storeKey: storeKey)

        let summary = try await accountSummary(for: client)
        await diagnostics.record(.info, category: "Auth", message: "Logged into homeserver", metadata: [
            "userID": summary.userID,
            "homeserver": summary.homeserver.absoluteString,
            "supportRoot": applicationSupportURL.path
        ])
        return AccountSessionActor(
            summary: summary,
            client: client,
            diagnostics: diagnostics,
            cacheRootURL: cacheRootURL(for: summary.accountID, applicationSupportURL: applicationSupportURL),
            database: database
        )
    }

    static func restore(
        persistedSession: PersistedAccountSession,
        sessionStore: StoredSessionStore,
        applicationSupportURL: URL,
        database: AppDatabase,
        diagnostics: DiagnosticsService
    ) async throws -> AccountSessionActor {
        let session = try sessionStore.restoreSession(for: persistedSession)
        let paths = try sessionStore.accountStorePaths(for: persistedSession.storeKey)

        let builder = ClientBuilder()
            .homeserverUrl(url: persistedSession.homeserverURL)
            .sessionPaths(dataPath: paths.dataPath, cachePath: paths.cachePath)
            .setSessionDelegate(sessionDelegate: sessionStore)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .userAgent(userAgent: "MatrixClient/0.1")

        let client = try await builder.build()
        try await client.restoreSession(session: session)
        let summary = try await accountSummary(for: client)
        await diagnostics.record(.info, category: "Auth", message: "Restored homeserver session", metadata: [
            "userID": summary.userID,
            "homeserver": summary.homeserver.absoluteString
        ])
        return AccountSessionActor(
            summary: summary,
            client: client,
            diagnostics: diagnostics,
            cacheRootURL: cacheRootURL(for: summary.accountID, applicationSupportURL: applicationSupportURL),
            database: database
        )
    }

    public func bootstrapIfNeeded() async throws {
        guard !bootstrapped else { return }
        bootstrapped = true

        let cachedRoomIDs = await restorePersistedRoomSummaries()
        await restorePersistedTimelinesIfNeeded(for: cachedRoomIDs)

        let syncService = try await client.syncService().finish()
        let roomListService = syncService.roomListService()
        let roomList = try await roomListService.allRooms()

        let listener = RoomListEntriesListenerProxy { [weak self] updates in
            Task {
                await self?.handleRoomListUpdates(updates)
            }
        }

        self.syncService = syncService
        self.roomListService = roomListService
        self.roomList = roomList
        self.roomListListener = listener
        self.roomListHandle = roomList.entries(listener: listener)
        let syncIndicatorListener = RoomListServiceSyncIndicatorListenerProxy { [weak self] indicator in
            Task {
                await self?.handleRoomListSyncIndicator(indicator)
            }
        }
        self.roomListSyncIndicatorListener = syncIndicatorListener
        self.roomListSyncIndicatorHandle = roomListService.syncIndicator(
            delayBeforeShowingInMs: 150,
            delayBeforeHidingInMs: 150,
            listener: syncIndicatorListener
        )

        await client.enableAllSendQueues(enable: true)
        await syncService.start()
        await setupVerification()
        startBackgroundRoomSweep()

        await diagnostics.record(.info, category: "Sync", message: "Started Sliding Sync service", metadata: [
            "userID": summary.userID
        ])
    }

    public func spaces() async -> [SpaceSummary] {
        await slidingSync.spaceSummaries()
    }

    public func roomListStream(spaceID: SpaceIdentifier?) async -> AsyncStream<[RoomSummary]> {
        await slidingSync.stream(spaceID: spaceID)
    }

    public func timelineStream(roomID: RoomIdentifier) async -> AsyncStream<[TimelineItem]> {
        await mediaCache.setActiveRoom(roomID)
        await restorePersistedTimelinesIfNeeded(for: [roomID])
        let stream = await timelineStore.stream(for: roomID)
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureTimelineSubscription(for: roomID)
            } catch {
                await self.diagnostics.record(.error, category: "Timeline", message: "Unable to initialize room timeline", metadata: [
                    "roomID": roomID.rawValue,
                    "error": error.localizedDescription
                ])
            }
        }
        return stream
    }

    public func mediaStateStream(roomID: RoomIdentifier) async -> AsyncStream<[String: TimelineMediaLoadState]> {
        await mediaCache.stream(for: roomID)
    }

    public func mediaWorkerStateStream() async -> AsyncStream<[MediaDownloadWorkerSnapshot]> {
        await mediaCache.workerStateStream()
    }

    public func verificationStateStream() -> AsyncStream<VerificationSnapshot> {
        verificationBroadcaster.stream()
    }

    public func prepareMedia(_ item: TimelineItem, prefetchOriginal: Bool) async {
        await mediaCache.prepareMedia(for: item, prefetchOriginal: prefetchOriginal)
    }

    public func resolveOriginalMediaURL(for item: TimelineItem) async -> URL? {
        await mediaCache.ensureOriginalAvailable(for: item)
    }

    public func requestVerification() async throws {
        let controller = try await ensureVerificationController()
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .requested
            snapshot.emojis = []
            snapshot.decimals = []
            snapshot.message = "Verification requested. Accept it on the other client, then start SAS."
        }
        do {
            try await controller.requestVerification()
        } catch {
            handleVerificationFailure(error)
            throw error
        }
    }

    public func startSasVerification() async throws {
        let controller = try await ensureVerificationController()
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .readyForSas
            snapshot.message = "Starting SAS verification…"
        }
        do {
            try await controller.startSasVerification()
        } catch {
            handleVerificationFailure(error)
            throw error
        }
    }

    public func approveVerification() async throws {
        guard let verificationController else { return }
        do {
            try await verificationController.approveVerification()
        } catch {
            handleVerificationFailure(error)
            throw error
        }
    }

    public func declineVerification() async throws {
        guard let verificationController else { return }
        do {
            try await verificationController.declineVerification()
            updateVerificationSnapshot { snapshot in
                snapshot.flow = .cancelled
                snapshot.emojis = []
                snapshot.decimals = []
                snapshot.message = "Verification rejected."
            }
        } catch {
            handleVerificationFailure(error)
            throw error
        }
    }

    public func cancelVerification() async throws {
        guard let verificationController else { return }
        do {
            try await verificationController.cancelVerification()
            updateVerificationSnapshot { snapshot in
                snapshot.flow = .cancelled
                snapshot.emojis = []
                snapshot.decimals = []
                snapshot.message = "Verification cancelled."
            }
        } catch {
            handleVerificationFailure(error)
            throw error
        }
    }

    public func roomDetails(roomID: RoomIdentifier) async -> RoomDetails? {
        if let cached = roomDetailsCache[roomID] {
            return cached
        }
        guard let roomItem = roomItemsByID[roomID] else { return nil }
        guard let details = await buildRoomDetails(from: roomItem) else { return nil }
        roomDetailsCache[roomID] = details
        return details
    }

    public func sendMessage(_ body: String, roomID: RoomIdentifier) async throws {
        try await ensureTimelineSubscription(for: roomID)
        guard let subscription = timelineSubscriptions[roomID] else {
            throw LiveMatrixSessionError.roomUnavailable(roomID.rawValue)
        }
        let content = messageEventContentFromMarkdown(md: body)
        let timeline = subscription.timeline
        let diagnostics = self.diagnostics
        let roomIDValue = roomID.rawValue
        let accountIDValue = summary.accountID.rawValue
        Task.detached(priority: .userInitiated) {
            do {
                _ = try await timeline.send(msg: content)
            } catch {
                await diagnostics.record(.error, category: "Timeline", message: "Failed to enqueue message", metadata: [
                    "roomID": roomIDValue,
                    "accountID": accountIDValue,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    public func resolveReceiptAvatarFileURL(for receipt: ReadReceipt) async -> URL? {
        guard let avatarURL = receipt.avatarURL else { return nil }
        return await receiptAvatarCache.fileURL(for: avatarURL)
    }

    public func markRoomAsRead(_ roomID: RoomIdentifier) async {
        guard let latestRemoteEventID = await latestRemoteEventID(for: roomID),
              lastMarkedReadEventIDByRoom[roomID] != latestRemoteEventID else {
            return
        }

        lastMarkedReadEventIDByRoom[roomID] = latestRemoteEventID
        readMarkerOverridesByRoom[roomID] = ReadMarkerOverride(eventID: latestRemoteEventID, appliedAt: .now)
        await clearUnreadCounts(for: roomID)

        do {
            let room: Room
            if let subscription = timelineSubscriptions[roomID] {
                room = subscription.room
            } else if let roomItem = roomItemsByID[roomID] {
                room = try roomItem.fullRoom()
            } else {
                throw LiveMatrixSessionError.roomUnavailable(roomID.rawValue)
            }

            try await room.markAsRead(receiptType: .read)
            try? await room.markAsRead(receiptType: .fullyRead)
        } catch {
            await diagnostics.record(.error, category: "Receipts", message: "Failed to mark room as read", metadata: [
                "roomID": roomID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    public func queueDiagnostics() async -> [SendQueueSnapshot] {
        []
    }

    private func setupVerification() async {
        do {
            _ = try await ensureVerificationController()
            let listener = VerificationStateListenerProxy { [weak self] status in
                Task {
                    await self?.applyVerificationState(status)
                }
            }
            verificationStateListener = listener
            verificationStateHandle = client.encryption().verificationStateListener(listener: listener)
            applyVerificationState(client.encryption().verificationState())
        } catch {
            await diagnostics.record(.error, category: "Verification", message: "Failed to initialize session verification", metadata: [
                "accountID": summary.accountID.rawValue,
                "error": error.localizedDescription
            ])
            handleVerificationFailure(error)
        }
    }

    private func ensureVerificationController() async throws -> SessionVerificationController {
        if let verificationController {
            return verificationController
        }

        let controller = try await client.getSessionVerificationController()
        let delegate = VerificationControllerDelegateProxy(
            onAccept: { [weak self] in
                await self?.handleVerificationAccepted()
            },
            onStartSas: { [weak self] in
                await self?.handleSasStarted()
            },
            onData: { [weak self] data in
                await self?.handleVerificationData(data)
            },
            onFail: { [weak self] in
                await self?.handleVerificationFailed()
            },
            onCancel: { [weak self] in
                await self?.handleVerificationCancelled()
            },
            onFinish: { [weak self] in
                await self?.handleVerificationFinished()
            }
        )
        controller.setDelegate(delegate: delegate)
        verificationController = controller
        verificationControllerDelegate = delegate
        return controller
    }

    private func applyVerificationState(_ state: VerificationState) {
        updateVerificationSnapshot { snapshot in
            snapshot.state = mapVerificationState(state)
            snapshot.deviceID = (try? client.deviceId()) ?? snapshot.deviceID

            guard snapshot.state != .verified else {
                snapshot.flow = .idle
                snapshot.emojis = []
                snapshot.decimals = []
                snapshot.message = "This session is verified."
                return
            }

            if snapshot.flow == .idle {
                snapshot.message = "This session is not verified yet."
            } else if snapshot.flow == .cancelled && (snapshot.message == nil || snapshot.message?.isEmpty == true) {
                snapshot.message = "Verification cancelled."
            } else if snapshot.flow == .failed && (snapshot.message == nil || snapshot.message?.isEmpty == true) {
                snapshot.message = "Verification failed."
            }
        }
    }

    private func handleVerificationAccepted() {
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .readyForSas
            snapshot.message = "Verification request accepted. Start SAS to compare the short auth string."
        }
    }

    private func handleSasStarted() {
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .readyForSas
            if snapshot.message == nil || snapshot.message == "Starting SAS verification…" {
                snapshot.message = "SAS started. Compare the code when it appears."
            }
        }
    }

    private func handleVerificationData(_ data: SessionVerificationData) {
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .showingChallenge
            snapshot.message = "Compare this short auth string with your other client, then confirm if it matches."
            switch data {
            case let .emojis(emojis, _):
                snapshot.emojis = emojis.map { VerificationEmoji(symbol: $0.symbol(), description: $0.description()) }
                snapshot.decimals = []
            case let .decimals(values):
                snapshot.emojis = []
                snapshot.decimals = values
            }
        }
    }

    private func handleVerificationFailed() {
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .failed
            snapshot.emojis = []
            snapshot.decimals = []
            snapshot.message = "Verification failed. Try again."
        }
        applyVerificationState(client.encryption().verificationState())
    }

    private func handleVerificationCancelled() {
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .cancelled
            snapshot.emojis = []
            snapshot.decimals = []
            snapshot.message = "Verification cancelled."
        }
        applyVerificationState(client.encryption().verificationState())
    }

    private func handleVerificationFinished() {
        applyVerificationState(client.encryption().verificationState())
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .idle
            snapshot.emojis = []
            snapshot.decimals = []
            snapshot.message = snapshot.state == .verified
                ? "This session is verified."
                : "Verification finished."
        }
    }

    private func handleVerificationFailure(_ error: Error) {
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .failed
            snapshot.emojis = []
            snapshot.decimals = []
            snapshot.message = error.localizedDescription
        }
    }

    private func updateVerificationSnapshot(_ mutate: (inout VerificationSnapshot) -> Void) {
        mutate(&verificationSnapshot)
        verificationBroadcaster.yield(verificationSnapshot)
    }

    private func mapVerificationState(_ state: VerificationState) -> VerificationStatus {
        switch state {
        case .unknown:
            return .unknown
        case .verified:
            return .verified
        case .unverified:
            return .unverified
        }
    }

    private func handleRoomListUpdates(_ updates: [RoomListEntriesUpdate]) async {
        applyRoomListUpdates(updates)
        await restorePersistedTimelinesIfNeeded(for: Array(roomItemsByID.keys))
        await subscribeToBackgroundRoomsIfNeeded(
            roomIDs: Array(roomItemsByID.keys),
            forceResubscribe: false,
            reason: "room-list-update"
        )
        await publishRoomListSnapshot()
    }

    private func applyRoomListUpdates(_ updates: [RoomListEntriesUpdate]) {
        for update in updates {
            switch update {
            case let .append(values):
                roomItems.append(contentsOf: values)
            case .clear:
                roomItems.removeAll()
            case let .pushFront(value):
                roomItems.insert(value, at: 0)
            case let .pushBack(value):
                roomItems.append(value)
            case .popFront:
                if !roomItems.isEmpty {
                    roomItems.removeFirst()
                }
            case .popBack:
                _ = roomItems.popLast()
            case let .insert(index, value):
                roomItems.insert(value, at: Int(index))
            case let .set(index, value):
                guard roomItems.indices.contains(Int(index)) else { continue }
                roomItems[Int(index)] = value
            case let .remove(index):
                guard roomItems.indices.contains(Int(index)) else { continue }
                roomItems.remove(at: Int(index))
            case let .truncate(length):
                roomItems = Array(roomItems.prefix(Int(length)))
            case let .reset(values):
                roomItems = values
            }
        }

        roomItemsByID = Dictionary(uniqueKeysWithValues: roomItems.map { item in
            (RoomIdentifier(rawValue: item.id()), item)
        })
        roomDetailsCache.removeAll()
    }

    private func publishRoomListSnapshot() async {
        let snapshot = roomItems
        let summaries = await withTaskGroup(of: RoomSummary?.self) { group in
            for item in snapshot {
                group.addTask {
                    await self.buildRoomSummary(from: item)
                }
            }

            var collected: [RoomSummary] = []
            for await summary in group {
                if let summary {
                    collected.append(summary)
                }
            }
            return collected.sorted { $0.timestamp > $1.timestamp }
        }

        await slidingSync.replace(spaces: [], rooms: summaries)
        await persistCurrentRoomSummarySnapshot()
    }

    private func ensureTimelineSubscription(for roomID: RoomIdentifier) async throws {
        if timelineSubscriptions[roomID] != nil {
            return
        }

        guard let roomListService else {
            throw LiveMatrixSessionError.roomUnavailable(roomID.rawValue)
        }

        let roomItem: RoomListItem
        if let existing = roomItemsByID[roomID] {
            roomItem = existing
        } else {
            roomItem = try roomListService.room(roomId: roomID.rawValue)
        }
        try roomListService.subscribeToRooms(
            roomIds: [roomID.rawValue],
            settings: roomSubscription(timelineLimit: Constants.activeRoomTimelineLimit)
        )
        backgroundSubscribedRoomIDs.insert(roomID)

        if !roomItem.isTimelineInitialized() {
            try await roomItem.initTimeline(eventTypeFilter: nil, internalIdPrefix: nil)
        }

        let room = try roomItem.fullRoom()
        room.enableSendQueue(enable: true)
        let timeline = try await room.timeline()
        let listener = TimelineListenerProxy { [weak self] diff in
            Task {
                await self?.handleTimelineDiff(diff, roomID: roomID, room: room)
            }
        }
        let handle = await timeline.addListener(listener: listener)
        timelineSubscriptions[roomID] = TimelineSubscription(room: room, timeline: timeline, listener: listener, handle: handle)
    }

    private func handleTimelineDiff(_ diffs: [MatrixRustSDK.TimelineDiff], roomID: RoomIdentifier, room: Room) async {
        var current = rawTimelineItemsByRoom[roomID, default: []]

        for diff in diffs {
            switch diff.change() {
            case .append:
                let incoming = await convert(items: diff.append() ?? [], roomID: roomID, room: room)
                current.append(contentsOf: mergeIncomingTimelineItems(incoming, existingItems: current))
            case .clear:
                current.removeAll()
            case .insert:
                if let insert = diff.insert(), let item = await convert(item: insert.item, roomID: roomID, room: room) {
                    let merged = mergeIncomingTimelineItem(item, existingItems: current)
                    current.insert(merged, at: min(Int(insert.index), current.count))
                }
            case .set:
                if let set = diff.set(),
                   current.indices.contains(Int(set.index)),
                   let item = await convert(item: set.item, roomID: roomID, room: room) {
                    current[Int(set.index)] = mergeIncomingTimelineItem(item, existingItems: current)
                }
            case .remove:
                if let index = diff.remove(), current.indices.contains(Int(index)) {
                    current.remove(at: Int(index))
                }
            case .pushBack:
                if let item = diff.pushBack(), let converted = await convert(item: item, roomID: roomID, room: room) {
                    current.append(mergeIncomingTimelineItem(converted, existingItems: current))
                }
            case .pushFront:
                if let item = diff.pushFront(), let converted = await convert(item: item, roomID: roomID, room: room) {
                    current.insert(mergeIncomingTimelineItem(converted, existingItems: current), at: 0)
                }
            case .popBack:
                _ = current.popLast()
            case .popFront:
                if !current.isEmpty {
                    current.removeFirst()
                }
            case .truncate:
                if let length = diff.truncate() {
                    current = Array(current.prefix(Int(length)))
                }
            case .reset:
                let incoming = await convert(items: diff.reset() ?? [], roomID: roomID, room: room)
                current = mergeIncomingTimelineItems(incoming, existingItems: current)
            }
        }

        current = TimelineItemReconciler.deduplicated(current)
        current = retainedTimelineItems(from: current)
        current = TimelineItemReconciler.normalizedReadReceipts(in: current)
        rawTimelineItemsByRoom[roomID] = current
        await prefetchMediaIfNeeded(from: current)
        let retainedMediaItems = current.filter { $0.media != nil }
        await mediaCache.prune(
            roomID: roomID,
            keepingItems: Array(retainedMediaItems)
        )
        await persistTimelineSnapshot(current, roomID: roomID)
        await timelineStore.replace(items: compactStatusItems(current), for: roomID)
        if let roomItem = roomItemsByID[roomID], let summary = await buildRoomSummary(from: roomItem) {
            await slidingSync.updateRoomSummary(summary)
            await persistCurrentRoomSummarySnapshot()
        }
    }

    private func mergeIncomingTimelineItems(_ incomingItems: [TimelineItem], existingItems: [TimelineItem]) -> [TimelineItem] {
        incomingItems.map { mergeIncomingTimelineItem($0, existingItems: existingItems) }
    }

    private func mergeIncomingTimelineItem(_ incomingItem: TimelineItem, existingItems: [TimelineItem]) -> TimelineItem {
        TimelineItemReconciler.merge(incomingItem, into: existingItems)
    }

    private func retainedTimelineItems(from items: [TimelineItem]) -> [TimelineItem] {
        Array(items.suffix(Constants.mediaRetentionMessageLimit))
    }

    private func restorePersistedTimelinesIfNeeded(for roomIDs: [RoomIdentifier]) async {
        for roomID in roomIDs where !restoredTimelineRoomIDs.contains(roomID) {
            restoredTimelineRoomIDs.insert(roomID)

            do {
                let records = try await timelineRepository.fetch(roomID: roomID.rawValue)
                guard !records.isEmpty else { continue }

                let decodedItems = records.compactMap { record in
                    decodeTimelineItem(from: record.payload)
                }
                guard !decodedItems.isEmpty else { continue }

                let retainedItems = TimelineItemReconciler.normalizedReadReceipts(
                    in: retainedTimelineItems(from: TimelineItemReconciler.deduplicated(decodedItems))
                )
                rawTimelineItemsByRoom[roomID] = retainedItems
                await prefetchMediaIfNeeded(from: retainedItems)
                await mediaCache.prune(
                    roomID: roomID,
                    keepingItems: retainedItems.filter { $0.media != nil }
                )
                await timelineStore.replace(items: compactStatusItems(retainedItems), for: roomID)
            } catch {
                await diagnostics.record(.error, category: "Persistence", message: "Failed to restore persisted room timeline", metadata: [
                    "roomID": roomID.rawValue,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func persistTimelineSnapshot(_ items: [TimelineItem], roomID: RoomIdentifier) async {
        let payloads = items.enumerated().compactMap { index, item -> PersistedTimelinePayload? in
            guard let payload = encodeTimelineItem(item) else { return nil }
            return PersistedTimelinePayload(itemID: item.id, sortIndex: index, payload: payload)
        }

        do {
            try await timelineRepository.replace(roomID: roomID.rawValue, items: payloads)
        } catch {
            await diagnostics.record(.error, category: "Persistence", message: "Failed to persist room timeline snapshot", metadata: [
                "roomID": roomID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    private func encodeTimelineItem(_ item: TimelineItem) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(item)
    }

    private func decodeTimelineItem(from payload: Data) -> TimelineItem? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(TimelineItem.self, from: payload)
    }

    private func encodeRoomSummary(_ summary: RoomSummary) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(summary)
    }

    private func decodeRoomSummary(from payload: Data) -> RoomSummary? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(RoomSummary.self, from: payload)
    }

    private func restorePersistedRoomSummaries() async -> [RoomIdentifier] {
        do {
            let payloads = try await roomSummaryRepository.fetchAll()
            let summaries = payloads.compactMap { decodeRoomSummary(from: $0.payload) }
                .sorted { $0.timestamp > $1.timestamp }
            guard !summaries.isEmpty else { return [] }

            await slidingSync.replace(spaces: [], rooms: summaries)
            return summaries.map(\.roomID)
        } catch {
            await diagnostics.record(.error, category: "Persistence", message: "Failed to restore cached room summaries", metadata: [
                "accountID": summary.accountID.rawValue,
                "error": error.localizedDescription
            ])
            return []
        }
    }

    private func persistCurrentRoomSummarySnapshot() async {
        let summaries = await slidingSync.roomSummaries(spaceID: nil)
        guard !summaries.isEmpty else { return }

        let payloads = summaries.compactMap { summary -> PersistedRoomSummaryPayload? in
            guard let payload = encodeRoomSummary(summary) else { return nil }
            return PersistedRoomSummaryPayload(roomID: summary.roomID.rawValue, payload: payload)
        }
        guard !payloads.isEmpty else { return }

        do {
            try await roomSummaryRepository.replaceAll(payloads)
        } catch {
            await diagnostics.record(.error, category: "Persistence", message: "Failed to persist room summary snapshot", metadata: [
                "accountID": summary.accountID.rawValue,
                "roomCount": "\(summaries.count)",
                "error": error.localizedDescription
            ])
        }
    }

    private func buildRoomSummary(from roomItem: RoomListItem) async -> RoomSummary? {
        let roomID = RoomIdentifier(rawValue: roomItem.id())
        let roomInfo = try? await roomItem.roomInfo()
        if roomInfo?.isSpace == true {
            return nil
        }

        let latestEvent = await roomItem.latestEvent()
        let topic = roomInfo?.topic ?? ""
        var notificationCount = roomInfo.map { Int(max($0.notificationCount, $0.numUnreadMessages)) } ?? 0
        var highlightCount = roomInfo.map { Int(max($0.highlightCount, $0.numUnreadMentions)) } ?? 0
        let isDirect = roomInfo?.isDirect ?? roomItem.isDirect()
        let displayName = roomInfo?.displayName ?? roomItem.displayName() ?? roomItem.canonicalAlias() ?? roomID.rawValue
        let cachedLatest = latestTimelineItem(for: roomID)
        let preview = cachedLatest.map(roomPreviewText(for:)) ?? latestEvent.flatMap { event in
            messagePreview(for: event)
        } ?? topic
        let timestamp = cachedLatest?.timestamp
            ?? latestEvent.map { Date(timeIntervalSince1970: Double($0.timestamp()) / 1_000) }
            ?? .distantPast
        let lastSenderDisplayName = cachedLatest?.senderDisplayName ?? latestEvent.map { senderDisplayName(forEvent: $0) } ?? displayName
        let isEncrypted = await roomItem.isEncrypted()
        let latestEventID = latestEvent?.eventId()

        if let override = readMarkerOverridesByRoom[roomID] {
            if notificationCount == 0 && highlightCount == 0 {
                readMarkerOverridesByRoom[roomID] = nil
            } else if latestEventID == override.eventID || latestEvent?.sender() == summary.userID {
                notificationCount = 0
                highlightCount = 0
            } else {
                readMarkerOverridesByRoom[roomID] = nil
            }
        }

        return RoomSummary(
            roomID: roomID,
            displayName: displayName,
            topic: topic,
            lastMessagePreview: preview,
            timestamp: timestamp,
            unreadCount: notificationCount,
            highlightCount: highlightCount,
            isDirect: isDirect,
            isEncrypted: isEncrypted,
            lastSenderDisplayName: lastSenderDisplayName
        )
    }

    private func latestTimelineItem(for roomID: RoomIdentifier) -> TimelineItem? {
        rawTimelineItemsByRoom[roomID, default: []]
            .last(where: { $0.kind == .message || $0.kind == .statusSummary })
    }

    private func latestRemoteEventID(for roomID: RoomIdentifier) async -> String? {
        if let cached = rawTimelineItemsByRoom[roomID, default: []]
            .last(where: { $0.id.hasPrefix("$") && $0.kind == .message })?
            .id {
            return cached
        }

        guard let roomItem = roomItemsByID[roomID], let latestEvent = await roomItem.latestEvent() else {
            return nil
        }
        return latestEvent.eventId()
    }

    private func clearUnreadCounts(for roomID: RoomIdentifier) async {
        guard let summary = await slidingSync.roomSummary(for: roomID) else { return }

        await slidingSync.updateRoomSummary(
            RoomSummary(
                roomID: summary.roomID,
                displayName: summary.displayName,
                topic: summary.topic,
                lastMessagePreview: summary.lastMessagePreview,
                timestamp: summary.timestamp,
                unreadCount: 0,
                highlightCount: 0,
                isDirect: summary.isDirect,
                isEncrypted: summary.isEncrypted,
                lastSenderDisplayName: summary.lastSenderDisplayName
            )
        )
        await persistCurrentRoomSummarySnapshot()
    }

    private func roomPreviewText(for item: TimelineItem) -> String {
        let preview = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.isDeleted else {
            return preview
        }
        if preview.isEmpty {
            return "Message removed locally"
        }
        return "\(preview) [Deleted]"
    }

    private func buildRoomDetails(from roomItem: RoomListItem) async -> RoomDetails? {
        guard let roomInfo = try? await roomItem.roomInfo() else { return nil }
        if roomInfo.isSpace {
            return nil
        }

        let roomID = RoomIdentifier(rawValue: roomInfo.id)
        let displayName = roomInfo.displayName ?? roomInfo.rawName ?? roomInfo.id
        let topic = roomInfo.topic ?? ""
        let memberCount = Int(roomInfo.joinedMembersCount)
        let pinnedMessages = roomInfo.pinnedEventIds
        let isEncrypted = await roomItem.isEncrypted()

        return RoomDetails(
            roomID: roomID,
            displayName: displayName,
            topic: topic,
            isEncrypted: isEncrypted,
            memberCount: memberCount,
            pinnedMessages: pinnedMessages
        )
    }

    private func convert(items: [MatrixRustSDK.TimelineItem], roomID: RoomIdentifier, room: Room) async -> [TimelineItem] {
        var result: [TimelineItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            if let converted = await convert(item: item, roomID: roomID, room: room) {
                result.append(converted)
            }
        }
        return result
    }

    private func convert(item: MatrixRustSDK.TimelineItem, roomID: RoomIdentifier, room: Room) async -> TimelineItem? {
        guard let event = item.asEvent() else { return nil }
        let content = event.content()
        let message = content.asMessage()
        let status = timelineStatusDetails(for: content)
        let media = message.flatMap(timelineMediaAttachment(for:))
        let senderID = event.sender()
        let timestamp = Date(timeIntervalSince1970: Double(event.timestamp()) / 1_000)
        let remoteEventID = event.eventId()
        let eventID = remoteEventID ?? item.uniqueId()
        let transactionID = event.transactionId().map(EventTransactionIdentifier.init(rawValue:))
        let rawReceipts = event.readReceipts()
        let receipts: ReceiptSummary
        if event.isOwn(), !rawReceipts.isEmpty {
            receipts = await mapReceipts(rawReceipts, roomID: roomID, room: room)
        } else {
            receipts = ReceiptSummary(sentAt: nil, deliveredAt: nil, readReceipts: [])
        }
        let deliveryState = MessageDeliveryState.reconciled(
            mappedState: mapDeliveryState(event.localSendState()),
            isOwnMessage: event.isOwn(),
            eventID: remoteEventID,
            hasReadReceipts: !receipts.readReceipts.isEmpty
        )
        let replyPreviewText: String?
        if let replyDetails = message?.inReplyTo() {
            replyPreviewText = replyPreview(for: replyDetails)
        } else {
            replyPreviewText = nil
        }
        let isEncrypted = (try? room.isEncrypted()) ?? false
        let isDeleted: Bool
        if case .redactedMessage = content.kind() {
            isDeleted = true
        } else {
            isDeleted = false
        }

        return TimelineItem(
            id: eventID,
            roomID: roomID,
            senderID: senderID,
            senderDisplayName: senderDisplayName(forEvent: event),
            body: timelineBody(for: content, message: message, status: status, media: media),
            timestamp: timestamp,
            kind: status == nil ? .message : .statusSummary,
            media: media,
            status: status,
            isOwnMessage: event.isOwn(),
            isEncrypted: isEncrypted,
            isEdited: message?.isEdited() ?? false,
            replyPreview: replyPreviewText,
            threadReplyCount: message?.isThreaded() == true ? 1 : 0,
            deliveryState: deliveryState,
            receipts: receipts,
            transactionID: transactionID,
            isDeleted: isDeleted,
            deletedAt: isDeleted ? timestamp : nil
        )
    }

    private func timelineBody(
        for content: TimelineItemContent,
        message: Message?,
        status: TimelineStatusDetails?,
        media: TimelineMediaAttachment?
    ) -> String {
        if let status {
            return status.renderedText
        }

        if let media {
            return mediaDisplayBody(for: media)
        }

        if let message {
            return message.body()
        }

        switch content.kind() {
        case .redactedMessage:
            return "Message removed"
        case let .sticker(body, _, _):
            return body
        case let .poll(question, _, _, _, _, _, _):
            return question
        case .callInvite:
            return "Call invite"
        case .callNotify:
            return "Call update"
        case .unableToDecrypt:
            return "Unable to decrypt message"
        case let .roomMembership(userId, userDisplayName, change):
            return membershipPreview(userID: userId, displayName: userDisplayName ?? userId, change: change)
        case let .profileChange(displayName, _, _, _):
            return displayName.map { "Profile changed: \($0)" } ?? "Profile changed"
        case let .state(stateKey, _):
            return "State update (\(stateKey))"
        case let .failedToParseMessageLike(eventType, _):
            return "Unsupported event: \(eventType)"
        case let .failedToParseState(eventType, _, _):
            return "Unsupported state: \(eventType)"
        case .message:
            return ""
        }
    }

    private func previewText(for content: TimelineItemContent, message: Message?) -> String {
        if let status = timelineStatusDetails(for: content) {
            return status.renderedText
        }
        if let media = message.flatMap(timelineMediaAttachment(for:)) {
            return mediaPreviewText(for: media)
        }
        return timelineBody(for: content, message: message, status: nil, media: nil)
    }

    private func timelineStatusDetails(for content: TimelineItemContent) -> TimelineStatusDetails? {
        guard case let .roomMembership(userID, userDisplayName, change) = content.kind() else {
            return nil
        }
        let displayName = userDisplayName ?? userID
        let action = mapMembershipAction(change)
        return TimelineStatusDetails(
            actorID: userID,
            actorDisplayName: displayName,
            action: action,
            renderedText: membershipPreview(userID: userID, displayName: displayName, change: change)
        )
    }

    private func mapMembershipAction(_ change: MembershipChange?) -> TimelineStatusAction {
        guard let change else { return .generic }
        switch change {
        case .none, .error:
            return .generic
        case .joined:
            return .joined
        case .left:
            return .left
        case .banned:
            return .banned
        case .unbanned:
            return .unbanned
        case .kicked:
            return .kicked
        case .invited:
            return .invited
        case .kickedAndBanned:
            return .kickedAndBanned
        case .invitationAccepted:
            return .acceptedInvite
        case .invitationRejected:
            return .rejectedInvite
        case .invitationRevoked:
            return .revokedInvite
        case .knocked:
            return .requestedJoin
        case .knockAccepted:
            return .allowedIn
        case .knockRetracted:
            return .cancelledJoinRequest
        case .knockDenied:
            return .denied
        case .notImplemented:
            return .generic
        }
    }

    private func membershipPreview(userID: String, displayName: String, change: MembershipChange?) -> String {
        let name = displayName.isEmpty ? userID : displayName
        return "\(name) \(mapMembershipAction(change).verbPhrase)"
    }

    private func timelineMediaAttachment(for message: Message) -> TimelineMediaAttachment? {
        switch message.msgtype() {
        case let .image(content):
            return TimelineMediaAttachment(
                kind: .image,
                body: content.body,
                filename: content.filename,
                sourceURL: content.source.url(),
                sourceJSON: content.source.toJson(),
                mimeType: content.info?.mimetype,
                thumbnailSourceURL: content.info?.thumbnailSource?.url(),
                thumbnailSourceJSON: content.info?.thumbnailSource?.toJson(),
                thumbnailMimeType: content.info?.thumbnailInfo?.mimetype,
                width: intValue(content.info?.width),
                height: intValue(content.info?.height),
                allowsDirectDownload: allowsDirectDownload(for: content.source)
            )
        case let .video(content):
            return TimelineMediaAttachment(
                kind: .video,
                body: content.body,
                filename: content.filename,
                sourceURL: content.source.url(),
                sourceJSON: content.source.toJson(),
                mimeType: content.info?.mimetype,
                thumbnailSourceURL: content.info?.thumbnailSource?.url(),
                thumbnailSourceJSON: content.info?.thumbnailSource?.toJson(),
                thumbnailMimeType: content.info?.thumbnailInfo?.mimetype,
                width: intValue(content.info?.width),
                height: intValue(content.info?.height),
                durationSeconds: content.info?.duration,
                allowsDirectDownload: allowsDirectDownload(for: content.source)
            )
        case let .audio(content):
            return TimelineMediaAttachment(
                kind: .audio,
                body: content.body,
                filename: content.filename,
                sourceURL: content.source.url(),
                sourceJSON: content.source.toJson(),
                mimeType: content.info?.mimetype,
                durationSeconds: content.info?.duration,
                allowsDirectDownload: allowsDirectDownload(for: content.source)
            )
        case let .file(content):
            return TimelineMediaAttachment(
                kind: .file,
                body: content.body,
                filename: content.filename,
                sourceURL: content.source.url(),
                sourceJSON: content.source.toJson(),
                mimeType: content.info?.mimetype,
                thumbnailSourceURL: content.info?.thumbnailSource?.url(),
                thumbnailSourceJSON: content.info?.thumbnailSource?.toJson(),
                thumbnailMimeType: content.info?.thumbnailInfo?.mimetype,
                allowsDirectDownload: allowsDirectDownload(for: content.source)
            )
        case .text, .notice, .emote, .location, .other:
            return nil
        }
    }

    private func allowsDirectDownload(for source: MediaSource) -> Bool {
        source.toJson() == mediaSourceFromUrl(url: source.url()).toJson()
    }

    private func mediaDisplayBody(for media: TimelineMediaAttachment) -> String {
        let trimmedBody = media.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFilename = media.filename?.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedBody.isEmpty, trimmedBody != trimmedFilename {
            return trimmedBody
        }
        if let trimmedFilename, !trimmedFilename.isEmpty {
            return trimmedFilename
        }
        return defaultMediaLabel(for: media.kind)
    }

    private func mediaPreviewText(for media: TimelineMediaAttachment) -> String {
        let body = mediaDisplayBody(for: media)
        let label = defaultMediaLabel(for: media.kind)
        return body == label ? label : "\(label): \(body)"
    }

    private func defaultMediaLabel(for kind: TimelineMediaKind) -> String {
        switch kind {
        case .image:
            return "Image"
        case .video:
            return "Video"
        case .audio:
            return "Audio"
        case .file:
            return "File"
        }
    }

    private func intValue(_ value: UInt64?) -> Int? {
        guard let value else { return nil }
        return Int(clamping: value)
    }

    private func senderDisplayName(forEvent event: EventTimelineItem) -> String {
        senderDisplayName(for: event.senderProfile(), fallback: event.sender())
    }

    private func senderDisplayName(for profile: ProfileDetails, fallback: String) -> String {
        switch profile {
        case let .ready(displayName, _, _):
            return displayName ?? fallback
        case .pending, .unavailable, .error:
            return fallback
        }
    }

    private func messagePreview(for event: EventTimelineItem) -> String {
        let content = event.content()
        let message = content.asMessage()
        return previewText(for: content, message: message)
    }

    private func replyPreview(for details: InReplyToDetails) -> String? {
        switch details.event {
        case let .ready(content, sender, senderProfile):
            let body = previewText(for: content, message: content.asMessage())
            let name = senderDisplayName(for: senderProfile, fallback: sender)
            return "\(name): \(body)"
        case .pending:
            return "Loading reply…"
        case .unavailable:
            return "Original message unavailable"
        case let .error(message):
            return message
        }
    }

    private func roomMemberProfile(for userID: String, roomID: RoomIdentifier, room: Room) async -> RoomMemberProfile {
        if let cached = roomMemberProfilesByRoom[roomID]?[userID] {
            return cached
        }

        let displayName = (try? await room.memberDisplayName(userId: userID)) ?? userID
        let avatarURL = try? await room.memberAvatarUrl(userId: userID)
        let profile = RoomMemberProfile(displayName: displayName, avatarURL: avatarURL)
        roomMemberProfilesByRoom[roomID, default: [:]][userID] = profile
        return profile
    }

    private func mapReceipts(_ receipts: [String: Receipt], roomID: RoomIdentifier, room: Room) async -> ReceiptSummary {
        var mapped: [ReadReceipt] = []
        mapped.reserveCapacity(receipts.count)

        for (userID, receipt) in receipts {
            guard userID != summary.userID else {
                continue
            }

            let profile = await roomMemberProfile(for: userID, roomID: roomID, room: room)
            mapped.append(
                ReadReceipt(
                    userID: userID,
                    displayName: profile.displayName,
                    avatarURL: profile.avatarURL,
                    readAt: receipt.timestamp.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
                )
            )
        }

        mapped.sort {
            switch ($0.readAt, $1.readAt) {
            case let (lhs?, rhs?):
                return lhs < rhs
            case (.none, .some):
                return false
            case (.some, .none):
                return true
            case (.none, .none):
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        let latestReadAt = mapped.compactMap(\.readAt).max()

        return ReceiptSummary(
            sentAt: latestReadAt,
            deliveredAt: latestReadAt,
            readReceipts: mapped
        )
    }

    private func mapDeliveryState(_ state: EventSendState?) -> MessageDeliveryState? {
        guard let state else { return nil }
        switch state {
        case .notSentYet:
            return .sending
        case .verifiedUserHasUnsignedDevice, .verifiedUserChangedIdentity:
            return .queued
        case let .sendingFailed(_, isRecoverable):
            return isRecoverable ? .queued : .permanentFailure
        case .sent:
            return .accepted
        }
    }

    private func compactStatusItems(_ items: [TimelineItem]) -> [TimelineItem] {
        guard !items.isEmpty else { return [] }

        var compacted: [TimelineItem] = []
        compacted.reserveCapacity(items.count)

        var index = 0
        while index < items.count {
            let item = items[index]
            guard item.kind == .statusSummary, item.status != nil else {
                compacted.append(item)
                index += 1
                continue
            }

            let startIndex = index
            var run: [TimelineItem] = []
            while index < items.count, items[index].kind == .statusSummary, items[index].status != nil {
                run.append(items[index])
                index += 1
            }

            if run.count == 1, let first = run.first {
                compacted.append(first)
                continue
            }

            guard let first = run.first, let last = run.last else { continue }
            let summaryText = summarizeStatusRun(run)
            compacted.append(
                TimelineItem(
                    id: "status-summary-\(items[startIndex].id)-\(last.id)",
                    roomID: first.roomID,
                    senderID: first.senderID,
                    senderDisplayName: "Room activity",
                    body: summaryText,
                    timestamp: last.timestamp,
                    kind: .statusSummary,
                    status: TimelineStatusDetails(
                        actorID: first.senderID,
                        actorDisplayName: "Room activity",
                        action: .generic,
                        renderedText: summaryText
                    ),
                    isOwnMessage: false,
                    isEncrypted: first.isEncrypted,
                    receipts: ReceiptSummary(sentAt: nil, deliveredAt: nil, readReceipts: []),
                    transactionID: nil
                )
            )
        }

        return compacted
    }

    private func summarizeStatusRun(_ items: [TimelineItem]) -> String {
        struct ActorSummary {
            let actorID: String
            let actorDisplayName: String
            var actions: [TimelineStatusAction]
        }

        var orderedActors: [ActorSummary] = []
        var actorIndexByID: [String: Int] = [:]

        for item in items {
            guard let status = item.status else { continue }
            if let existingIndex = actorIndexByID[status.actorID] {
                if orderedActors[existingIndex].actions.last != status.action {
                    orderedActors[existingIndex].actions.append(status.action)
                }
            } else {
                actorIndexByID[status.actorID] = orderedActors.count
                orderedActors.append(
                    ActorSummary(
                        actorID: status.actorID,
                        actorDisplayName: status.actorDisplayName,
                        actions: [status.action]
                    )
                )
            }
        }

        var phrases: [String] = []
        var groupedSingles: [TimelineStatusAction: [String]] = [:]
        var groupedOrder: [TimelineStatusAction] = []

        for actor in orderedActors {
            let uniqueActions = actor.actions
            if uniqueActions.count > 1 {
                phrases.append("\(actor.actorDisplayName) \(renderedActionList(uniqueActions))")
                continue
            }

            let action = uniqueActions.first ?? .generic
            if groupedSingles[action] == nil {
                groupedSingles[action] = []
                groupedOrder.append(action)
            }
            groupedSingles[action, default: []].append(actor.actorDisplayName)
        }

        for action in groupedOrder {
            guard let names = groupedSingles[action], !names.isEmpty else { continue }
            phrases.append(compactStatusPhrase(for: names, action: action))
        }

        return phrases.joined(separator: ". ")
    }

    private func renderedActionList(_ actions: [TimelineStatusAction]) -> String {
        let verbs = actions.map(\.verbPhrase)
        switch verbs.count {
        case 0:
            return TimelineStatusAction.generic.verbPhrase
        case 1:
            return verbs[0]
        case 2:
            return "\(verbs[0]) and \(verbs[1])"
        default:
            return verbs.dropLast().joined(separator: ", ") + ", and " + verbs.last!
        }
    }

    private func compactStatusPhrase(for names: [String], action: TimelineStatusAction) -> String {
        switch names.count {
        case 1:
            return "\(names[0]) \(action.verbPhrase)"
        case 2:
            return "\(names[0]) and \(names[1]) \(action.verbPhrase)"
        case 3:
            return "\(names[0]), \(names[1]), and \(names[2]) \(action.verbPhrase)"
        default:
            let othersCount = names.count - 2
            return "\(names[0]), \(names[1]), and \(othersCount) others \(action.verbPhrase)"
        }
    }

    private func prefetchMediaIfNeeded(from items: [TimelineItem]) async {
        for item in retainedTimelineItems(from: items) {
            guard let media = item.media else { continue }
            let shouldPrefetchOriginal = media.kind == .image || media.kind == .video
            await mediaCache.prepareMedia(for: item, prefetchOriginal: shouldPrefetchOriginal)
        }
    }

    private func roomSubscription(timelineLimit: Int) -> RoomSubscription {
        RoomSubscription(
            requiredState: [
                RequiredState(key: "m.room.encryption", value: ""),
                RequiredState(key: "m.room.name", value: ""),
                RequiredState(key: "m.room.topic", value: ""),
                RequiredState(key: "m.room.avatar", value: "")
            ],
            timelineLimit: UInt32(timelineLimit),
            includeHeroes: true
        )
    }

    private func subscribeToBackgroundRoomsIfNeeded(
        roomIDs: [RoomIdentifier],
        forceResubscribe: Bool,
        reason: String
    ) async {
        guard let roomListService, !roomIDs.isEmpty else { return }

        let roomIDsToSubscribe: [RoomIdentifier]
        if forceResubscribe {
            roomIDsToSubscribe = roomIDs
        } else {
            roomIDsToSubscribe = roomIDs.filter { !backgroundSubscribedRoomIDs.contains($0) }
        }

        guard !roomIDsToSubscribe.isEmpty else {
            await ensureBackgroundRoomInfoSubscriptions(for: roomIDs)
            await ensureBackgroundTimelineSubscriptions(for: roomIDs)
            return
        }

        let settings = roomSubscription(timelineLimit: Constants.backgroundRoomTimelineLimit)
        for chunkStart in stride(from: 0, to: roomIDsToSubscribe.count, by: Constants.backgroundSubscriptionBatchSize) {
            let chunk = Array(roomIDsToSubscribe[chunkStart..<min(chunkStart + Constants.backgroundSubscriptionBatchSize, roomIDsToSubscribe.count)])
            do {
                try roomListService.subscribeToRooms(roomIds: chunk.map(\.rawValue), settings: settings)
                backgroundSubscribedRoomIDs.formUnion(chunk)
            } catch {
                await diagnostics.record(.error, category: "Sync", message: "Failed to subscribe background room batch", metadata: [
                    "reason": reason,
                    "batchCount": "\(chunk.count)",
                    "error": error.localizedDescription
                ])
            }
        }

        await ensureBackgroundRoomInfoSubscriptions(for: roomIDs)
        await ensureBackgroundTimelineSubscriptions(for: roomIDs)
    }

    private func startBackgroundRoomSweep() {
        backgroundRoomSweepTask?.cancel()
        backgroundRoomSweepTask = Task { [weak self] in
            guard let self else { return }
            await self.performBackgroundRoomSweep(reason: "startup", forceResubscribe: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: Constants.backgroundSweepInterval)
                guard !Task.isCancelled else { return }
                await self.performBackgroundRoomSweep(reason: "periodic-sweep", forceResubscribe: true)
            }
        }
    }

    private func performBackgroundRoomSweep(reason: String, forceResubscribe: Bool) async {
        let roomIDs = Array(roomItemsByID.keys)
        await subscribeToBackgroundRoomsIfNeeded(
            roomIDs: roomIDs,
            forceResubscribe: forceResubscribe,
            reason: reason
        )
        await publishRoomListSnapshot()
    }

    private func ensureBackgroundRoomInfoSubscriptions(for roomIDs: [RoomIdentifier]) async {
        for roomID in roomIDs where roomInfoSubscriptions[roomID] == nil {
            let roomItem: RoomListItem
            do {
                if let existing = roomItemsByID[roomID] {
                    roomItem = existing
                } else if let roomListService {
                    roomItem = try roomListService.room(roomId: roomID.rawValue)
                } else {
                    continue
                }

                let room = try roomItem.fullRoom()
                let listener = RoomInfoListenerProxy { [weak self] in
                    Task {
                        await self?.handleBackgroundRoomInfoUpdate(roomID: roomID)
                    }
                }
                let handle = room.subscribeToRoomInfoUpdates(listener: listener)
                roomInfoSubscriptions[roomID] = RoomInfoSubscription(room: room, listener: listener, handle: handle)
            } catch {
                await diagnostics.record(.error, category: "Sync", message: "Failed to subscribe to background room info", metadata: [
                    "roomID": roomID.rawValue,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func ensureBackgroundTimelineSubscriptions(for roomIDs: [RoomIdentifier]) async {
        for roomID in roomIDs where timelineSubscriptions[roomID] == nil {
            do {
                try await ensureTimelineSubscription(for: roomID)
            } catch {
                await diagnostics.record(.error, category: "Timeline", message: "Failed to subscribe to background room timeline", metadata: [
                    "roomID": roomID.rawValue,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func handleBackgroundRoomInfoUpdate(roomID: RoomIdentifier) async {
        guard let roomItem = roomItemsByID[roomID], let summary = await buildRoomSummary(from: roomItem) else {
            return
        }

        if let details = await buildRoomDetails(from: roomItem) {
            roomDetailsCache[roomID] = details
        }
        await slidingSync.updateRoomSummary(summary)
        await persistCurrentRoomSummarySnapshot()
    }

    private func handleRoomListSyncIndicator(_ indicator: RoomListServiceSyncIndicator) async {
        guard indicator == .hide else { return }
        await performBackgroundRoomSweep(reason: "sync-indicator-hide", forceResubscribe: false)
    }

    private static func accountSummary(for client: Client) async throws -> AccountSummary {
        let userID = try client.userId()
        let displayName = (try? await client.displayName()) ?? userID
        let homeserver = URL(string: client.homeserver()) ?? URL(string: "https://invalid.local")!
        return AccountSummary(
            accountID: AccountIdentifier(rawValue: userID),
            displayName: displayName,
            userID: userID,
            homeserver: homeserver,
            avatarSymbolName: "person.crop.circle.fill"
        )
    }

    private static func cacheRootURL(for accountID: AccountIdentifier, applicationSupportURL: URL) -> URL {
        let sanitizedAccountID = accountID.rawValue.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return applicationSupportURL
            .appendingPathComponent("MediaCache", isDirectory: true)
            .appendingPathComponent(sanitizedAccountID, isDirectory: true)
    }
}
#else
public actor AccountSessionActor {
    public let summary: AccountSummary

    public init(summary: AccountSummary, database: AppDatabase, diagnostics: DiagnosticsService) {
        self.summary = summary
    }
}
#endif
