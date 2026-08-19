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

private final class ClassicSyncListenerProxy: SyncListenerV2, @unchecked Sendable {
    private let handler: @Sendable (SyncResponseV2) -> Void
    init(handler: @escaping @Sendable (SyncResponseV2) -> Void) { self.handler = handler }
    func onUpdate(response: SyncResponseV2) { handler(response) }
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

    func didReceiveVerificationRequest(details _: SessionVerificationRequestDetails) {}

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

private struct SpaceHierarchyResponse: Decodable {
    let rooms: [SpaceHierarchyRoom]
    let nextBatch: String?

    private enum CodingKeys: String, CodingKey {
        case rooms
        case nextBatch = "next_batch"
    }
}

private struct SpaceHierarchyRoom: Decodable, Sendable {
    let roomID: String
    let name: String?
    let topic: String?
    let canonicalAlias: String?
    let roomType: String?
    let worldReadable: Bool?
    let joinRule: String?

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case name
        case topic
        case canonicalAlias = "canonical_alias"
        case roomType = "room_type"
        case worldReadable = "world_readable"
        case joinRule = "join_rule"
    }
}

public actor AccountSessionActor {
    private enum SyncTransport { case sliding, classicV2 }
    private enum Constants {
        static let backgroundSweepInterval: Duration = .seconds(30)
        static let backgroundRoomTimelineLimit = 64
        static let activeRoomTimelineLimit = 500
        static let backgroundSubscriptionBatchSize = 64
        static let mediaRetentionMessageLimit = 500
    }

    public let summary: AccountSummary

    private let diagnostics: DiagnosticsService
    private let client: Client
    private let syncTransport: SyncTransport
    private let slidingSync = SlidingSyncCoordinator(spaces: [], rooms: [])
    private let timelineStore = TimelineStore()
    private let mediaCache: MatrixMediaCache
    private let receiptAvatarCache: ReceiptAvatarCache
    private let timelineRepository: PersistedTimelineRepository
    private let roomSummaryRepository: PersistedRoomSummaryRepository
    private let notificationBroadcaster = AsyncBroadcaster<RoomNotificationEvent>()
    private let verificationBroadcaster = AsyncBroadcaster<VerificationSnapshot>()

    private var syncService: SyncService?
    private var classicSyncListener: ClassicSyncListenerProxy?
    private var classicSyncHandle: TaskHandle?
    private var classicRooms: [RoomIdentifier: Room] = [:]
    private var roomListService: RoomListService?
    private var roomList: RoomList?
    private var roomListDynamicEntries: RoomListEntriesWithDynamicAdaptersResult?
    private var roomListListener: RoomListEntriesListenerProxy?
    private var roomListHandle: TaskHandle?
    private var roomListSyncIndicatorListener: RoomListServiceSyncIndicatorListenerProxy?
    private var roomListSyncIndicatorHandle: TaskHandle?
    private var roomItems: [Room] = []
    private var roomItemsByID: [RoomIdentifier: Room] = [:]
    private var timelineSubscriptions: [RoomIdentifier: TimelineSubscription] = [:]
    private var roomInfoSubscriptions: [RoomIdentifier: RoomInfoSubscription] = [:]
    private var sdkTimelineItemsByRoom: [RoomIdentifier: [TimelineItem]] = [:]
    private var displayTimelineItemsByRoom: [RoomIdentifier: [TimelineItem]] = [:]
    private var roomMemberProfilesByRoom: [RoomIdentifier: [String: RoomMemberProfile]] = [:]
    private var roomDetailsCache: [RoomIdentifier: RoomDetails] = [:]
    private var discoveredSpaceIDsByRoom: [RoomIdentifier: Set<SpaceIdentifier>] = [:]
    private var backgroundSubscribedRoomIDs: Set<RoomIdentifier> = []
    private var restoredTimelineRoomIDs: Set<RoomIdentifier> = []
    private var notificationPrimedRoomIDs: Set<RoomIdentifier> = []
    private var lastSeenNotificationEventIDByRoom: [RoomIdentifier: String] = [:]
    private var lastMarkedReadEventIDByRoom: [RoomIdentifier: String] = [:]
    private var readMarkerOverridesByRoom: [RoomIdentifier: ReadMarkerOverride] = [:]
    private var backgroundRoomSweepTask: Task<Void, Never>?
    private var pendingSendMonitorTasks: [RoomIdentifier: Task<Void, Never>] = [:]
    private var lastSpaceHierarchyRefreshAt: Date?
    private var verificationController: SessionVerificationController?
    private var verificationControllerDelegate: VerificationControllerDelegateProxy?
    private var verificationStateListener: VerificationStateListenerProxy?
    private var verificationStateHandle: TaskHandle?
    private var verificationSnapshot: VerificationSnapshot
    private var bootstrapped = false

    private init(summary: AccountSummary, client: Client, syncTransport: SyncTransport, diagnostics: DiagnosticsService, cacheRootURL: URL, database: AppDatabase) {
        self.summary = summary
        self.client = client
        self.syncTransport = syncTransport
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
            syncTransport: loginDetails.slidingSyncVersion() == .native ? .sliding : .classicV2,
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
            .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
            .userAgent(userAgent: "MatrixClient/0.1")

        let client = try await builder.build()
        try await client.restoreSession(session: session)
        let summary = try await accountSummary(for: client)
        let loginDetails = await client.homeserverLoginDetails()
        await diagnostics.record(.info, category: "Auth", message: "Restored homeserver session", metadata: [
            "userID": summary.userID,
            "homeserver": summary.homeserver.absoluteString
        ])
        return AccountSessionActor(
            summary: summary,
            client: client,
            syncTransport: loginDetails.slidingSyncVersion() == .native ? .sliding : .classicV2,
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

        if syncTransport == .classicV2 {
            try await startClassicSync()
            await setupVerification()
            return
        }

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
        let dynamicEntries = roomList.entriesWithDynamicAdapters(pageSize: 100, listener: listener)
        self.roomListDynamicEntries = dynamicEntries
        self.roomListHandle = dynamicEntries.entriesStream()
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

        await ensureDiscoveredSpaceSummariesExist()
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

    public func allKnownRoomSummaries() async -> [RoomSummary] {
        await slidingSync.allKnownRoomSummaries()
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

    public func notificationEventStream() -> AsyncStream<RoomNotificationEvent> {
        notificationBroadcaster.stream()
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
        _ = try await ensureVerificationController()
        updateVerificationSnapshot { snapshot in
            snapshot.flow = .requested
            snapshot.emojis = []
            snapshot.decimals = []
            snapshot.message = "Verification requested. Accept it on the other client, then start SAS."
        }
        do {
            try await ensureVerificationController().requestDeviceVerification()
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
        if let room = classicRooms[roomID] {
            return RoomDetails(roomID: roomID, displayName: room.displayName() ?? roomID.rawValue, topic: room.topic() ?? "", isEncrypted: await room.isEncrypted(), memberCount: Int(room.joinedMembersCount()), pinnedMessages: [])
        }
        guard let roomItem = roomItemsByID[roomID] else { return nil }
        guard let details = await buildRoomDetails(from: roomItem) else { return nil }
        roomDetailsCache[roomID] = details
        return details
    }

    public func joinRoom(_ roomID: RoomIdentifier) async throws {
        _ = try await client.joinRoomById(roomId: roomID.rawValue)
        await performBackgroundRoomSweep(reason: "manual-join", forceResubscribe: true)
    }

    public func sendMessage(_ body: String, roomID: RoomIdentifier) async throws {
        if syncTransport == .classicV2 {
            try await ensureTimelineSubscription(for: roomID)
            guard let subscription = timelineSubscriptions[roomID] else { throw LiveMatrixSessionError.roomUnavailable(roomID.rawValue) }
            _ = try await subscription.timeline.send(msg: messageEventContentFromMarkdown(md: body))
            return
        }
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
                await self.schedulePendingSendMonitor(for: roomID)
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
            if let classicRoom = classicRooms[roomID] {
                room = classicRoom
            } else
            if let subscription = timelineSubscriptions[roomID] {
                room = subscription.room
            } else if let roomItem = roomItemsByID[roomID] {
                room = roomItem
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

    public func setForeground(_ isForeground: Bool) async {
        await mediaCache.setSessionForeground(isForeground)
    }

    public func shutdown(logoutRemote: Bool) async {
        backgroundRoomSweepTask?.cancel()
        backgroundRoomSweepTask = nil

        classicSyncHandle?.cancel()
        classicSyncHandle = nil
        classicSyncListener = nil

        roomListHandle?.cancel()
        roomListHandle = nil
        roomListListener = nil

        roomListSyncIndicatorHandle?.cancel()
        roomListSyncIndicatorHandle = nil
        roomListSyncIndicatorListener = nil

        verificationStateHandle?.cancel()
        verificationStateHandle = nil
        verificationStateListener = nil
        verificationControllerDelegate = nil
        verificationController = nil

        for task in pendingSendMonitorTasks.values {
            task.cancel()
        }
        pendingSendMonitorTasks.removeAll()

        for subscription in timelineSubscriptions.values {
            subscription.handle.cancel()
            subscription.room.enableSendQueue(enable: false)
        }
        timelineSubscriptions.removeAll()

        for subscription in roomInfoSubscriptions.values {
            subscription.handle.cancel()
        }
        roomInfoSubscriptions.removeAll()

        roomItems.removeAll()
        roomItemsByID.removeAll()
        classicRooms.removeAll()
        sdkTimelineItemsByRoom.removeAll()
        displayTimelineItemsByRoom.removeAll()
        roomDetailsCache.removeAll()
        roomMemberProfilesByRoom.removeAll()
        backgroundSubscribedRoomIDs.removeAll()
        notificationPrimedRoomIDs.removeAll()
        lastSeenNotificationEventIDByRoom.removeAll()
        lastMarkedReadEventIDByRoom.removeAll()
        readMarkerOverridesByRoom.removeAll()

        await client.enableAllSendQueues(enable: false)

        if let syncService {
            do {
                try await syncService.stop()
            } catch {
                await diagnostics.record(.error, category: "Sync", message: "Failed to stop Sliding Sync service during shutdown", metadata: [
                    "accountID": summary.accountID.rawValue,
                    "error": error.localizedDescription
                ])
            }
            self.syncService = nil
        }

        roomListService = nil
        roomList = nil

        guard logoutRemote else { return }

        do {
            _ = try await client.logout()
        } catch {
            await diagnostics.record(.error, category: "Auth", message: "Remote logout failed", metadata: [
                "accountID": summary.accountID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    private func startClassicSync() async throws {
        let listener = ClassicSyncListenerProxy { [weak self] response in
            Task { await self?.handleClassicSync(response) }
        }
        classicSyncListener = listener
        let initialResponse = try await client.syncOnceV2(settings: SyncSettingsV2(fullState: true))
        await handleClassicSync(initialResponse)
        classicSyncHandle = client.syncV2(
            settings: SyncSettingsV2(timeoutMs: 30_000),
            listener: listener
        )
        await diagnostics.record(.info, category: "Sync", message: "Started classic /sync service", metadata: [
            "userID": summary.userID
        ])
    }

    private func handleClassicSync(_: SyncResponseV2) async {
        let rooms = client.rooms()
        var summaries: [RoomSummary] = []
        var updatedRooms: [RoomIdentifier: Room] = [:]
        for room in rooms {
            let roomID = RoomIdentifier(rawValue: room.id())
            updatedRooms[roomID] = room
            let isSpace = room.isSpace()
            let timelineItems = displayTimelineItemsByRoom[roomID] ?? []
            let latest = timelineItems.last
            summaries.append(RoomSummary(
                roomID: roomID,
                displayName: room.displayName() ?? room.canonicalAlias() ?? roomID.rawValue,
                topic: room.topic() ?? "",
                lastMessagePreview: latest.map(roomPreviewText(for:)) ?? (isSpace ? "Space" : ""),
                timestamp: latest?.timestamp ?? .distantPast,
                unreadCount: 0,
                highlightCount: 0,
                isDirect: await room.isDirect(),
                isEncrypted: await room.isEncrypted(),
                lastSenderDisplayName: latest?.senderDisplayName ?? "",
                canonicalAlias: room.canonicalAlias(),
                roomKind: isSpace ? .space : .room
            ))
        }
        classicRooms = updatedRooms
        await slidingSync.replace(spaces: [], rooms: summaries.sorted { $0.timestamp > $1.timestamp })
        await persistCurrentRoomSummarySnapshot()
        for roomID in updatedRooms.keys {
            do {
                try await ensureTimelineSubscription(for: roomID)
            } catch {
                await diagnostics.record(.error, category: "Timeline", message: "Unable to initialize classic-sync room timeline", metadata: ["roomID": roomID.rawValue, "error": error.localizedDescription])
            }
        }
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
        let persistedSpaceAssignmentsExist = !discoveredSpaceIDsByRoom.isEmpty
        let knownSpaces = await slidingSync.spaceSummaries()
        let hasKnownSpaces = persistedSpaceAssignmentsExist || !knownSpaces.isEmpty
        if hasKnownSpaces {
            await refreshSpaceHierarchyIfNeeded(force: true)
        }
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

        if syncTransport == .classicV2 {
            let resolvedRoom = try client.getRoom(roomId: roomID.rawValue)
            guard let room = classicRooms[roomID] ?? resolvedRoom else { throw LiveMatrixSessionError.roomUnavailable(roomID.rawValue) }
            classicRooms[roomID] = room
            room.enableSendQueue(enable: true)
            let timeline = try await room.timeline()
            let listener = TimelineListenerProxy { [weak self] diff in Task { await self?.handleTimelineDiff(diff, roomID: roomID, room: room, timeline: timeline) } }
            let handle = await timeline.addListener(listener: listener)
            timelineSubscriptions[roomID] = TimelineSubscription(room: room, timeline: timeline, listener: listener, handle: handle)
            return
        }
        guard let roomListService else { throw LiveMatrixSessionError.roomUnavailable(roomID.rawValue) }

        let roomItem: Room
        if let existing = roomItemsByID[roomID] {
            roomItem = existing
        } else {
            roomItem = try roomListService.room(roomId: roomID.rawValue)
        }
        try await roomListService.subscribeToRooms(roomIds: [roomID.rawValue])
        backgroundSubscribedRoomIDs.insert(roomID)

        let room = roomItem
        room.enableSendQueue(enable: true)
        let timeline = try await room.timeline()
        let listener = TimelineListenerProxy { [weak self] diff in
            Task {
                await self?.handleTimelineDiff(diff, roomID: roomID, room: room, timeline: timeline)
            }
        }
        let handle = await timeline.addListener(listener: listener)
        timelineSubscriptions[roomID] = TimelineSubscription(room: room, timeline: timeline, listener: listener, handle: handle)
    }

    private func handleTimelineDiff(
        _ diffs: [MatrixRustSDK.TimelineDiff],
        roomID: RoomIdentifier,
        room: Room,
        timeline: Timeline
    ) async {
        var sdkItems = sdkTimelineItemsByRoom[roomID, default: []]
        let previousItems = displayTimelineItemsByRoom[roomID, default: []]

        for diff in diffs {
            switch diff {
            case let .append(values):
                let incoming = await convert(items: values, roomID: roomID, room: room)
                sdkItems.append(contentsOf: mergeIncomingTimelineItems(incoming, existingItems: sdkItems))
            case .clear:
                sdkItems.removeAll()
            case let .insert(index, value):
                if let item = await convert(item: value, roomID: roomID, room: room) {
                    let merged = mergeIncomingTimelineItem(item, existingItems: sdkItems)
                    sdkItems.insert(merged, at: min(Int(index), sdkItems.count))
                }
            case let .set(index, value):
                if sdkItems.indices.contains(Int(index)), let item = await convert(item: value, roomID: roomID, room: room) {
                    sdkItems[Int(index)] = mergeIncomingTimelineItem(item, existingItems: sdkItems)
                }
            case let .remove(index):
                if sdkItems.indices.contains(Int(index)) {
                    sdkItems.remove(at: Int(index))
                }
            case let .pushBack(value):
                if let converted = await convert(item: value, roomID: roomID, room: room) {
                    sdkItems.append(mergeIncomingTimelineItem(converted, existingItems: sdkItems))
                }
            case let .pushFront(value):
                if let converted = await convert(item: value, roomID: roomID, room: room) {
                    sdkItems.insert(mergeIncomingTimelineItem(converted, existingItems: sdkItems), at: 0)
                }
            case .popBack:
                _ = sdkItems.popLast()
            case .popFront:
                if !sdkItems.isEmpty {
                    sdkItems.removeFirst()
                }
            case let .truncate(length):
                sdkItems = Array(sdkItems.prefix(Int(length)))
            case let .reset(values):
                let incoming = await convert(items: values, roomID: roomID, room: room)
                sdkItems = mergeResetTimelineItems(incoming, existingItems: sdkItems)
            }
        }

        let resolvedSDKItems = await refreshPendingDeliveryStates(
            in: sdkItems,
            roomID: roomID,
            room: room,
            timeline: timeline
        )
        sdkTimelineItemsByRoom[roomID] = resolvedSDKItems
        let current = derivedDisplayTimeline(from: resolvedSDKItems)
        displayTimelineItemsByRoom[roomID] = current
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
        if let notification = await makeRoomNotificationEvent(
            roomID: roomID,
            room: room,
            previousItems: previousItems,
            currentItems: current
        ) {
            notificationBroadcaster.yield(notification)
        }
        if current.contains(where: requiresPendingDeliveryMonitoring(_:)) {
            schedulePendingSendMonitor(for: roomID)
        }
    }

    private func mergeIncomingTimelineItems(_ incomingItems: [TimelineItem], existingItems: [TimelineItem]) -> [TimelineItem] {
        incomingItems.map { mergeIncomingTimelineItem($0, existingItems: existingItems) }
    }

    private func mergeResetTimelineItems(_ incomingItems: [TimelineItem], existingItems: [TimelineItem]) -> [TimelineItem] {
        guard !existingItems.isEmpty else {
            return incomingItems
        }
        return existingItems + mergeIncomingTimelineItems(incomingItems, existingItems: existingItems)
    }

    private func mergeIncomingTimelineItem(_ incomingItem: TimelineItem, existingItems: [TimelineItem]) -> TimelineItem {
        TimelineItemReconciler.merge(incomingItem, into: existingItems)
    }

    private func retainedTimelineItems(from items: [TimelineItem]) -> [TimelineItem] {
        Array(items.suffix(Constants.mediaRetentionMessageLimit))
    }

    private func derivedDisplayTimeline(
        from sdkItems: [TimelineItem]
    ) -> [TimelineItem] {
        var current = sdkItems
        current = TimelineItemReconciler.deduplicated(current)
        current = TimelineItemReconciler.repairedPendingRemoteEchoes(in: current)
        current = retainedTimelineItems(from: current)
        current = TimelineItemReconciler.normalizedReadReceipts(in: current)
        return current
    }

    private func schedulePendingSendMonitor(for roomID: RoomIdentifier) {
        pendingSendMonitorTasks[roomID]?.cancel()
        guard timelineSubscriptions[roomID] != nil else { return }

        pendingSendMonitorTasks[roomID] = Task { [self, roomID] in
            await monitorPendingSendState(for: roomID)
        }
    }

    private func monitorPendingSendState(for roomID: RoomIdentifier) async {
        defer {
            pendingSendMonitorTasks.removeValue(forKey: roomID)
        }

        for _ in 0..<80 {
            if Task.isCancelled {
                return
            }

            guard let subscription = timelineSubscriptions[roomID] else {
                return
            }

            let current = displayTimelineItemsByRoom[roomID, default: []]
            let hasPending = current.contains(where: requiresPendingDeliveryMonitoring(_:))
            guard hasPending else { return }

            let refreshed = await refreshPendingDeliveryStates(
                in: current,
                roomID: roomID,
                room: subscription.room,
                timeline: subscription.timeline
            )

            if refreshed != current {
                await publishResolvedTimelineState(refreshed, roomID: roomID)
            }

            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func refreshPendingDeliveryStates(
        in items: [TimelineItem],
        roomID: RoomIdentifier,
        room: Room,
        timeline: Timeline
    ) async -> [TimelineItem] {
        guard !items.isEmpty else { return items }

        var updated = items
        var changed = false

        for index in updated.indices {
            let item = updated[index]
            guard item.kind == .message,
                  item.isOwnMessage,
                  requiresPendingDeliveryMonitoring(item) else {
                continue
            }

            guard let refreshed = await refreshedPendingTimelineItem(
                from: item,
                roomID: roomID,
                items: items,
                room: room,
                timeline: timeline
            ) else {
                continue
            }

            guard refreshed != item else { continue }
            updated[index] = refreshed
            changed = true
        }

        return changed ? updated : items
    }

    private func refreshedPendingTimelineItem(
        from item: TimelineItem,
        roomID: RoomIdentifier,
        items: [TimelineItem],
        room: Room,
        timeline: Timeline
    ) async -> TimelineItem? {
        // The current SDK no longer offers a transaction-ID lookup on Timeline.
        // Timeline diffs provide the authoritative local-echo transition instead.
        _ = (roomID, items, room, timeline)
        return nil
    }

    private func requiresPendingDeliveryMonitoring(_ item: TimelineItem) -> Bool {
        guard item.kind == .message, item.isOwnMessage else {
            return false
        }

        switch item.deliveryState {
        case .queued, .sending:
            return !item.id.hasPrefix("$")
        case .accepted, .echoed, .permanentFailure, .none:
            return false
        }
    }

    private func latestRemoteEchoFallback(
        for item: TimelineItem,
        roomID: RoomIdentifier,
        items: [TimelineItem]
    ) async -> String? {
        if let localMatch = matchingRemoteEcho(for: item, in: items) {
            return localMatch.id
        }

        if let sdkMatch = matchingRemoteEcho(for: item, in: sdkTimelineItemsByRoom[roomID, default: []]) {
            return sdkMatch.id
        }

        if let displayMatch = matchingRemoteEcho(for: item, in: displayTimelineItemsByRoom[roomID, default: []]) {
            return displayMatch.id
        }

        return nil
    }

    private func matchingRemoteEcho(for pendingItem: TimelineItem, in items: [TimelineItem]) -> TimelineItem? {
        items.reversed().first { candidate in
            candidate.kind == .message &&
                candidate.isOwnMessage &&
                candidate.id.hasPrefix("$") &&
                candidate.roomID == pendingItem.roomID &&
                candidate.senderID == pendingItem.senderID &&
                abs(candidate.timestamp.timeIntervalSince(pendingItem.timestamp)) <= 600 &&
                normalizedTimelineBody(candidate.body) == normalizedTimelineBody(pendingItem.body) &&
                mediaSignature(for: candidate) == mediaSignature(for: pendingItem)
        }
    }

    private func normalizedTimelineBody(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func mediaSignature(for item: TimelineItem) -> String {
        item.media.map {
            "\($0.kind.rawValue)|\($0.sourceURL)|\($0.thumbnailSourceURL ?? "")|\($0.filename ?? "")"
        } ?? ""
    }

    private func publishResolvedTimelineState(_ items: [TimelineItem], roomID: RoomIdentifier) async {
        let retained = TimelineItemReconciler.normalizedReadReceipts(
            in: retainedTimelineItems(
                from: TimelineItemReconciler.repairedPendingRemoteEchoes(
                    in: TimelineItemReconciler.deduplicated(items)
                )
            )
        )
        sdkTimelineItemsByRoom[roomID] = synchronizedSDKTimelineItems(
            existing: sdkTimelineItemsByRoom[roomID, default: []],
            resolved: retained
        )
        displayTimelineItemsByRoom[roomID] = retained
        await persistTimelineSnapshot(retained, roomID: roomID)
        await timelineStore.replace(items: compactStatusItems(retained), for: roomID)
    }

    private func synchronizedSDKTimelineItems(existing: [TimelineItem], resolved: [TimelineItem]) -> [TimelineItem] {
        guard !existing.isEmpty, !resolved.isEmpty else { return existing }

        let resolvedByID = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        let resolvedByTransactionID = Dictionary(
            uniqueKeysWithValues: resolved.compactMap { item in
                item.transactionID.map { ($0, item) }
            }
        )

        return existing.map { item in
            if let resolvedItem = resolvedByID[item.id]
                ?? item.transactionID.flatMap({ resolvedByTransactionID[$0] })
                ?? matchingRemoteEcho(for: item, in: resolved) {
                return TimelineItem(
                    id: resolvedItem.id.hasPrefix("$") ? resolvedItem.id : item.id,
                    roomID: item.roomID,
                    senderID: item.senderID,
                    senderDisplayName: item.senderDisplayName,
                    body: item.body,
                    timestamp: item.timestamp,
                    kind: item.kind,
                    media: item.media,
                    status: item.status,
                    isOwnMessage: item.isOwnMessage,
                    isEncrypted: item.isEncrypted,
                    isEdited: item.isEdited || resolvedItem.isEdited,
                    replyPreview: item.replyPreview ?? resolvedItem.replyPreview,
                    threadReplyCount: max(item.threadReplyCount, resolvedItem.threadReplyCount),
                    deliveryState: resolvedItem.deliveryState ?? item.deliveryState,
                    receipts: resolvedItem.receipts.readReceipts.isEmpty ? item.receipts : resolvedItem.receipts,
                    transactionID: item.transactionID ?? resolvedItem.transactionID,
                    isDeleted: item.isDeleted || resolvedItem.isDeleted,
                    deletedAt: resolvedItem.deletedAt ?? item.deletedAt
                )
            }

            return item
        }
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
                displayTimelineItemsByRoom[roomID] = retainedItems
                primeNotificationBaseline(for: roomID, items: retainedItems)
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

            discoveredSpaceIDsByRoom = Dictionary(
                uniqueKeysWithValues: summaries.compactMap { summary in
                    guard !summary.spaceIDs.isEmpty else { return nil }
                    return (summary.roomID, Set(summary.spaceIDs))
                }
            )
            await slidingSync.replace(spaces: [], rooms: summaries)
            await ensureDiscoveredSpaceSummariesExist()
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
        let summaries = await slidingSync.allKnownRoomSummaries()
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

    private func buildRoomSummary(from roomItem: Room) async -> RoomSummary? {
        let roomID = RoomIdentifier(rawValue: roomItem.id())
        let roomInfo = try? await roomItem.roomInfo()
        let isSpaceRoom = roomItem.isSpace()
        let topic = roomItem.topic() ?? ""
        var notificationCount = roomInfo.map { Int(max($0.notificationCount, $0.numUnreadMessages)) } ?? 0
        var highlightCount = roomInfo.map { Int(max($0.highlightCount, $0.numUnreadMentions)) } ?? 0
        let isDirect = await roomItem.isDirect()
        let displayName = roomItem.displayName() ?? roomItem.canonicalAlias() ?? roomID.rawValue
        let cachedLatest = latestTimelineItem(for: roomID)
        let fallbackPreview = isSpaceRoom ? (topic.isEmpty ? "Space" : topic) : topic
        let preview = cachedLatest.map(roomPreviewText(for:)) ??
            fallbackPreview
        let timestamp = cachedLatest?.timestamp
            ?? .distantPast
        let lastSenderDisplayName = cachedLatest?.senderDisplayName ?? displayName
        let isEncrypted = await roomItem.isEncrypted()
        let latestEventID = cachedLatest?.id
        let membership = mapRoomMembership(roomItem.membership())

        if let override = readMarkerOverridesByRoom[roomID] {
            if notificationCount == 0 && highlightCount == 0 {
                readMarkerOverridesByRoom[roomID] = nil
            } else if latestEventID == override.eventID {
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
            lastSenderDisplayName: lastSenderDisplayName,
            canonicalAlias: roomInfo?.canonicalAlias ?? roomItem.canonicalAlias(),
            roomKind: isSpaceRoom ? .space : .room,
            membership: membership,
            spaceIDs: currentSpaceIDs(for: roomID),
            isPublic: roomInfo?.isPublic ?? false,
            canJoin: membership != .joined && membership != .left
        )
    }

    private func currentSpaceIDs(for roomID: RoomIdentifier) -> [SpaceIdentifier] {
        Array(discoveredSpaceIDsByRoom[roomID, default: []]).sorted { $0.rawValue < $1.rawValue }
    }

    private func ensureDiscoveredSpaceSummariesExist() async {
        let discoveredSpaceIDs = Set(discoveredSpaceIDsByRoom.values.flatMap { $0 })
        guard !discoveredSpaceIDs.isEmpty else { return }

        let knownRoomSummaries = await slidingSync.allKnownRoomSummaries()
        let knownSpaceIDs = Set(
            knownRoomSummaries
                .filter(\.isSpace)
                .map { SpaceIdentifier(rawValue: $0.roomID.rawValue) }
        )

        var inserted = false
        for spaceID in discoveredSpaceIDs.subtracting(knownSpaceIDs) {
            guard let summary = await buildSpaceSummary(spaceID: spaceID) else { continue }
            await slidingSync.updateRoomSummary(summary)
            inserted = true
        }

        if inserted {
            await persistCurrentRoomSummarySnapshot()
        }
    }

    private func refreshSpaceHierarchyIfNeeded(force: Bool) async {
        let now = Date()
        let minimumRefreshInterval: TimeInterval = force ? 15 : 120
        if let lastSpaceHierarchyRefreshAt,
           now.timeIntervalSince(lastSpaceHierarchyRefreshAt) < minimumRefreshInterval {
            return
        }

        let knownSpaces = await slidingSync.allKnownRoomSummaries()
            .filter(\.isSpace)
            .map { SpaceIdentifier(rawValue: $0.roomID.rawValue) }
        let discoveredSpaces = discoveredSpaceIDsByRoom.values.flatMap { $0 }
        let spaceIDs = Set(knownSpaces).union(discoveredSpaces).sorted { $0.rawValue < $1.rawValue }
        guard !spaceIDs.isEmpty else { return }

        lastSpaceHierarchyRefreshAt = now

        for spaceID in spaceIDs {
            await refreshSpaceHierarchy(for: spaceID)
        }
    }

    private func refreshSpaceHierarchy(for spaceID: SpaceIdentifier) async {
        do {
            let rooms = try await fetchSpaceHierarchyRooms(for: spaceID)
            await applySpaceHierarchy(spaceID: spaceID, rooms: rooms)
        } catch {
            await diagnostics.record(.debug, category: "Spaces", message: "Failed to refresh space hierarchy", metadata: [
                "spaceID": spaceID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    private func fetchSpaceHierarchyRooms(for spaceID: SpaceIdentifier) async throws -> [SpaceHierarchyRoom] {
        let session = try client.session()
        let baseURL = summary.homeserver
        guard let encodedRoomID = encodedPathComponent(spaceID.rawValue) else {
            return []
        }

        let decoder = JSONDecoder()
        var collectedByRoomID: [String: SpaceHierarchyRoom] = [:]
        var fromToken: String?

        while true {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = "/_matrix/client/v1/rooms/\(encodedRoomID)/hierarchy"
            var queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "suggested_only", value: "false")
            ]
            if let fromToken {
                queryItems.append(URLQueryItem(name: "from", value: fromToken))
            }
            components?.queryItems = queryItems

            guard let url = components?.url else { return Array(collectedByRoomID.values) }

            var request = URLRequest(url: url)
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                guard (200 ... 299).contains(httpResponse.statusCode) else {
                    throw NSError(
                        domain: "MatrixClient.SpaceHierarchy",
                        code: httpResponse.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Hierarchy request failed with status \(httpResponse.statusCode)."]
                    )
                }
            }

            let decoded = try decoder.decode(SpaceHierarchyResponse.self, from: data)
            for room in decoded.rooms {
                collectedByRoomID[room.roomID] = room
            }

            guard let nextBatch = decoded.nextBatch, !nextBatch.isEmpty, nextBatch != fromToken else {
                break
            }
            fromToken = nextBatch
        }

        return Array(collectedByRoomID.values)
    }

    private func applySpaceHierarchy(spaceID: SpaceIdentifier, rooms: [SpaceHierarchyRoom]) async {
        let validRoomIDs = Set(rooms.map(\.roomID))
        var changed = false

        let previouslyAssignedRoomIDs = discoveredSpaceIDsByRoom.compactMap { roomID, spaceIDs in
            spaceIDs.contains(spaceID) ? roomID : nil
        }
        for roomID in previouslyAssignedRoomIDs where !validRoomIDs.contains(roomID.rawValue) {
            var memberships = discoveredSpaceIDsByRoom[roomID, default: []]
            if memberships.remove(spaceID) != nil {
                discoveredSpaceIDsByRoom[roomID] = memberships
                await updateSpaceAssignments(for: roomID)
                changed = true
            }
        }

        for hierarchyRoom in rooms {
            let roomID = RoomIdentifier(rawValue: hierarchyRoom.roomID)
            var memberships = discoveredSpaceIDsByRoom[roomID, default: []]
            let inserted = memberships.insert(spaceID).inserted
            discoveredSpaceIDsByRoom[roomID] = memberships

            if let existingSummary = await slidingSync.roomSummary(for: roomID) {
                let updatedSummary = RoomSummary(
                    roomID: existingSummary.roomID,
                    displayName: existingSummary.displayName,
                    topic: existingSummary.topic,
                    lastMessagePreview: existingSummary.lastMessagePreview,
                    timestamp: existingSummary.timestamp,
                    unreadCount: existingSummary.unreadCount,
                    highlightCount: existingSummary.highlightCount,
                    isDirect: existingSummary.isDirect,
                    isEncrypted: existingSummary.isEncrypted,
                    lastSenderDisplayName: existingSummary.lastSenderDisplayName,
                    canonicalAlias: existingSummary.canonicalAlias,
                    roomKind: existingSummary.roomKind,
                    membership: existingSummary.membership,
                    spaceIDs: currentSpaceIDs(for: roomID),
                    isPublic: existingSummary.isPublic,
                    canJoin: existingSummary.canJoin
                )
                if updatedSummary != existingSummary {
                    await slidingSync.updateRoomSummary(updatedSummary)
                    changed = true
                } else if inserted {
                    changed = true
                }
            } else {
                await slidingSync.updateRoomSummary(roomSummary(from: hierarchyRoom, spaceID: spaceID))
                changed = true
            }
        }

        if let spaceSummary = await buildSpaceSummary(spaceID: spaceID) {
            await slidingSync.updateRoomSummary(spaceSummary)
            changed = true
        }

        if changed {
            await persistCurrentRoomSummarySnapshot()
        }
    }

    private func updateSpaceAssignments(for roomID: RoomIdentifier) async {
        if let existingSummary = await slidingSync.roomSummary(for: roomID) {
            await slidingSync.updateRoomSummary(
                RoomSummary(
                    roomID: existingSummary.roomID,
                    displayName: existingSummary.displayName,
                    topic: existingSummary.topic,
                    lastMessagePreview: existingSummary.lastMessagePreview,
                    timestamp: existingSummary.timestamp,
                    unreadCount: existingSummary.unreadCount,
                    highlightCount: existingSummary.highlightCount,
                    isDirect: existingSummary.isDirect,
                    isEncrypted: existingSummary.isEncrypted,
                    lastSenderDisplayName: existingSummary.lastSenderDisplayName,
                    canonicalAlias: existingSummary.canonicalAlias,
                    roomKind: existingSummary.roomKind,
                    membership: existingSummary.membership,
                    spaceIDs: currentSpaceIDs(for: roomID),
                    isPublic: existingSummary.isPublic,
                    canJoin: existingSummary.canJoin
                )
            )
        }
    }

    private func roomSummary(from hierarchyRoom: SpaceHierarchyRoom, spaceID _: SpaceIdentifier) -> RoomSummary {
        let roomID = RoomIdentifier(rawValue: hierarchyRoom.roomID)
        let membership: RoomMembership
        if roomItemsByID[roomID] != nil {
            membership = .joined
        } else {
            membership = .notJoined
        }

        let topic = hierarchyRoom.topic ?? ""
        let displayName = hierarchyRoom.name ?? hierarchyRoom.canonicalAlias ?? hierarchyRoom.roomID
        let isPublic = hierarchyRoom.worldReadable == true || hierarchyRoom.joinRule == "public"
        let roomKind: RoomSummaryKind = hierarchyRoom.roomType == "m.space" ? .space : .room

        return RoomSummary(
            roomID: roomID,
            displayName: displayName,
            topic: topic,
            lastMessagePreview: topic.isEmpty ? membership.label : topic,
            timestamp: .distantPast,
            unreadCount: 0,
            highlightCount: 0,
            isDirect: false,
            isEncrypted: false,
            lastSenderDisplayName: displayName,
            canonicalAlias: hierarchyRoom.canonicalAlias,
            roomKind: roomKind,
            membership: membership,
            spaceIDs: currentSpaceIDs(for: roomID),
            isPublic: isPublic,
            canJoin: membership != .left && (membership == .joined || isPublic)
        )
    }

    private func encodedPathComponent(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))
    }

    private func mapRoomMembership(_ membership: Membership) -> RoomMembership {
        switch membership {
        case .joined:
            return .joined
        case .invited:
            return .invited
        case .left:
            return .left
        case .knocked, .banned:
            return .notJoined
        }
    }

    private func registerSpaceMembership(spaceID: SpaceIdentifier, for roomID: RoomIdentifier) async {
        var spaceIDs = discoveredSpaceIDsByRoom[roomID, default: []]
        let inserted = spaceIDs.insert(spaceID).inserted
        discoveredSpaceIDsByRoom[roomID] = spaceIDs

        guard inserted else { return }
        await ensureDiscoveredSpaceSummariesExist()

        if let existingSummary = await slidingSync.roomSummary(for: roomID) {
            await slidingSync.updateRoomSummary(
                RoomSummary(
                    roomID: existingSummary.roomID,
                    displayName: existingSummary.displayName,
                    topic: existingSummary.topic,
                    lastMessagePreview: existingSummary.lastMessagePreview,
                    timestamp: existingSummary.timestamp,
                    unreadCount: existingSummary.unreadCount,
                    highlightCount: existingSummary.highlightCount,
                    isDirect: existingSummary.isDirect,
                    isEncrypted: existingSummary.isEncrypted,
                    lastSenderDisplayName: existingSummary.lastSenderDisplayName,
                    canonicalAlias: existingSummary.canonicalAlias,
                    roomKind: existingSummary.roomKind,
                    membership: existingSummary.membership,
                    spaceIDs: currentSpaceIDs(for: roomID),
                    isPublic: existingSummary.isPublic,
                    canJoin: existingSummary.canJoin
                )
            )
            await persistCurrentRoomSummarySnapshot()
            return
        }

        if let previewSummary = await buildPreviewRoomSummary(roomID: roomID, spaceID: spaceID) {
            await slidingSync.updateRoomSummary(previewSummary)
            await persistCurrentRoomSummarySnapshot()
        }
    }

    private func buildPreviewRoomSummary(roomID: RoomIdentifier, spaceID: SpaceIdentifier) async -> RoomSummary? {
        let viaServers = summary.homeserver.host.map { [$0] } ?? []
        let preview = try? await client.getRoomPreviewFromRoomId(roomId: roomID.rawValue, viaServers: viaServers)
        let membership: RoomMembership
        let displayName: String
        let topic: String
        let canonicalAlias: String?
        let isPublic: Bool
        let canJoin: Bool

        if let preview {
            let info = preview.info()
            if info.membership == .joined {
                membership = .joined
            } else if info.membership == .invited {
                membership = .invited
            } else {
                membership = .notJoined
            }
            displayName = info.name ?? info.canonicalAlias ?? roomID.rawValue
            topic = info.topic ?? ""
            canonicalAlias = info.canonicalAlias
            isPublic = info.joinRule == .public
            canJoin = membership != .left && (membership == .invited || isPublic || info.joinRule == .knock)
        } else {
            membership = .notJoined
            displayName = roomID.rawValue
            topic = ""
            canonicalAlias = nil
            isPublic = false
            canJoin = true
        }

        return RoomSummary(
            roomID: roomID,
            displayName: displayName,
            topic: topic,
            lastMessagePreview: topic.isEmpty ? membership.label : topic,
            timestamp: .distantPast,
            unreadCount: 0,
            highlightCount: 0,
            isDirect: false,
            isEncrypted: false,
            lastSenderDisplayName: "",
            canonicalAlias: canonicalAlias,
            roomKind: .room,
            membership: membership,
            spaceIDs: currentSpaceIDs(for: roomID),
            isPublic: isPublic,
            canJoin: canJoin
        )
    }

    private func buildSpaceSummary(spaceID: SpaceIdentifier) async -> RoomSummary? {
        let roomID = RoomIdentifier(rawValue: spaceID.rawValue)

        if let roomItem = roomItemsByID[roomID] ?? (try? roomListService?.room(roomId: roomID.rawValue)),
           let built = await buildRoomSummary(from: roomItem) {
            return RoomSummary(
                roomID: built.roomID,
                displayName: built.displayName,
                topic: built.topic,
                lastMessagePreview: built.topic.isEmpty ? "Space" : built.topic,
                timestamp: built.timestamp,
                unreadCount: built.unreadCount,
                highlightCount: built.highlightCount,
                isDirect: false,
                isEncrypted: built.isEncrypted,
                lastSenderDisplayName: built.lastSenderDisplayName,
                canonicalAlias: built.canonicalAlias,
                roomKind: .space,
                membership: built.membership,
                spaceIDs: [],
                isPublic: built.isPublic,
                canJoin: built.canJoin
            )
        }

        let viaServers = summary.homeserver.host.map { [$0] } ?? []
        if let preview = try? await client.getRoomPreviewFromRoomId(roomId: roomID.rawValue, viaServers: viaServers) {
            let info = preview.info()
            let membership: RoomMembership
            if info.membership == .joined {
                membership = .joined
            } else if info.membership == .invited {
                membership = .invited
            } else {
                membership = .notJoined
            }

            return RoomSummary(
                roomID: roomID,
                displayName: info.name ?? info.canonicalAlias ?? roomID.rawValue,
                topic: info.topic ?? "",
                lastMessagePreview: (info.topic ?? "").isEmpty ? "Space" : (info.topic ?? ""),
                timestamp: .distantPast,
                unreadCount: 0,
                highlightCount: 0,
                isDirect: false,
                isEncrypted: false,
                lastSenderDisplayName: info.name ?? info.canonicalAlias ?? roomID.rawValue,
                canonicalAlias: info.canonicalAlias,
                roomKind: .space,
                membership: membership,
                spaceIDs: [],
                isPublic: info.joinRule == .public,
                canJoin: membership != .left && (membership == .invited || info.joinRule == .public || info.joinRule == .knock)
            )
        }

        return RoomSummary(
            roomID: roomID,
            displayName: roomID.rawValue,
            topic: "",
            lastMessagePreview: "Space",
            timestamp: .distantPast,
            unreadCount: 0,
            highlightCount: 0,
            isDirect: false,
            isEncrypted: false,
            lastSenderDisplayName: roomID.rawValue,
            canonicalAlias: nil,
            roomKind: .space,
            membership: .joined,
            spaceIDs: [],
            isPublic: false,
            canJoin: false
        )
    }

    private func updateSpaceRelationshipsIfNeeded(content: TimelineItemContent, roomID: RoomIdentifier) async {
        guard case let .state(stateKey, otherState) = content else { return }

        switch otherState {
        case .spaceParent:
            await registerSpaceMembership(
                spaceID: SpaceIdentifier(rawValue: stateKey),
                for: roomID
            )
        case .spaceChild:
            await registerSpaceMembership(
                spaceID: SpaceIdentifier(rawValue: roomID.rawValue),
                for: RoomIdentifier(rawValue: stateKey)
            )
        default:
            break
        }
    }

    private func latestTimelineItem(for roomID: RoomIdentifier) -> TimelineItem? {
        displayTimelineItemsByRoom[roomID, default: []]
            .last(where: { $0.kind == .message || $0.kind == .statusSummary })
    }

    private func primeNotificationBaseline(for roomID: RoomIdentifier, items: [TimelineItem]) {
        notificationPrimedRoomIDs.insert(roomID)
        lastSeenNotificationEventIDByRoom[roomID] = latestIncomingRemoteMessage(in: items)?.id
    }

    private func makeRoomNotificationEvent(
        roomID: RoomIdentifier,
        room: Room,
        previousItems: [TimelineItem],
        currentItems: [TimelineItem]
    ) async -> RoomNotificationEvent? {
        let latestIncomingEventID = latestIncomingRemoteMessage(in: currentItems)?.id

        guard notificationPrimedRoomIDs.contains(roomID) else {
            notificationPrimedRoomIDs.insert(roomID)
            lastSeenNotificationEventIDByRoom[roomID] = latestIncomingEventID
            return nil
        }

        let previousIDs = Set(previousItems.map(\.id))
        let lastSeenEventID = lastSeenNotificationEventIDByRoom[roomID]
        lastSeenNotificationEventIDByRoom[roomID] = latestIncomingEventID

        guard let candidate = currentItems.reversed().first(where: { item in
            isNotifiableIncomingMessage(item) &&
                !previousIDs.contains(item.id) &&
                item.id != lastSeenEventID
        }) else {
            return nil
        }

        guard await shouldDeliverNotification(for: roomID, room: room) else {
            return nil
        }

        let roomInfo = try? await room.roomInfo()
        let slidingSummary = await slidingSync.roomSummary(for: roomID)
        let roomDisplayName = roomInfo?.displayName
            ?? roomItemsByID[roomID]?.displayName()
            ?? slidingSummary?.displayName
            ?? roomID.rawValue
        let previewText = candidate.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "New message"
            : candidate.body

        return RoomNotificationEvent(
            accountID: summary.accountID,
            accountDisplayName: summary.displayName,
            roomID: roomID,
            roomDisplayName: roomDisplayName,
            senderID: candidate.senderID,
            senderDisplayName: candidate.senderDisplayName,
            eventID: candidate.id,
            previewText: previewText,
            timestamp: candidate.timestamp
        )
    }

    private func latestIncomingRemoteMessage(in items: [TimelineItem]) -> TimelineItem? {
        items.last(where: isNotifiableIncomingMessage)
    }

    private func isNotifiableIncomingMessage(_ item: TimelineItem) -> Bool {
        item.kind == .message &&
            !item.isOwnMessage &&
            item.id.hasPrefix("$") &&
            !item.isDeleted
    }

    private func shouldDeliverNotification(for roomID: RoomIdentifier, room: Room) async -> Bool {
        guard let roomInfo = try? await room.roomInfo() else {
            return true
        }

        let effectiveMode = roomInfo.cachedUserDefinedNotificationMode
        switch effectiveMode {
        case .mute:
            return false
        case .mentionsAndKeywordsOnly:
            return roomInfo.highlightCount > 0 || roomInfo.numUnreadMentions > 0
        case .allMessages, .none:
            return true
        }
    }

    private func latestRemoteEventID(for roomID: RoomIdentifier) async -> String? {
        if let cached = displayTimelineItemsByRoom[roomID, default: []]
            .last(where: { $0.id.hasPrefix("$") && $0.kind == .message })?
            .id {
            return cached
        }

        return nil
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
                lastSenderDisplayName: summary.lastSenderDisplayName,
                canonicalAlias: summary.canonicalAlias,
                roomKind: summary.roomKind,
                membership: summary.membership,
                spaceIDs: summary.spaceIDs,
                isPublic: summary.isPublic,
                canJoin: summary.canJoin
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

    private func buildRoomDetails(from roomItem: Room) async -> RoomDetails? {
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
        let content = event.content
        await updateSpaceRelationshipsIfNeeded(content: content, roomID: roomID)
        let message = messageContent(from: content)
        let status = timelineStatusDetails(for: content)
        let media = message.flatMap(timelineMediaAttachment(for:))
        let senderID = event.sender
        let timestamp = Date(timeIntervalSince1970: Double(event.timestamp) / 1_000)
        let remoteEventID: String? = if case let .eventId(eventID) = event.eventOrTransactionId { eventID } else { nil }
        let eventID: String = if case let .eventId(eventID) = event.eventOrTransactionId { eventID } else if case let .transactionId(transactionID) = event.eventOrTransactionId { transactionID } else { item.uniqueId().id }
        let transactionID: EventTransactionIdentifier? = if case let .transactionId(value) = event.eventOrTransactionId { EventTransactionIdentifier(rawValue: value) } else { nil }
        let rawReceipts = event.readReceipts
        let receipts: ReceiptSummary
        if event.isOwn, !rawReceipts.isEmpty {
            receipts = await mapReceipts(rawReceipts, roomID: roomID, room: room)
        } else {
            receipts = ReceiptSummary(sentAt: nil, deliveredAt: nil, readReceipts: [])
        }
        let deliveryState = MessageDeliveryState.reconciled(
            mappedState: mapDeliveryState(event.localSendState),
            isOwnMessage: event.isOwn,
            eventID: remoteEventID,
            hasReadReceipts: !receipts.readReceipts.isEmpty
        )
        let replyPreviewText: String?
        if let replyDetails = messageLikeContent(from: content)?.inReplyTo {
            replyPreviewText = replyPreview(for: replyDetails)
        } else {
            replyPreviewText = nil
        }
        let isEncrypted = await room.isEncrypted()
        let isDeleted: Bool
        if case let .msgLike(msgLike) = content, case .redacted = msgLike.kind {
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
            isOwnMessage: event.isOwn,
            isEncrypted: isEncrypted,
            isEdited: message?.isEdited ?? false,
            replyPreview: replyPreviewText,
            threadReplyCount: messageLikeContent(from: content)?.threadRoot == nil ? 0 : 1,
            deliveryState: deliveryState,
            receipts: receipts,
            transactionID: transactionID,
            isDeleted: isDeleted,
            deletedAt: isDeleted ? timestamp : nil
        )
    }

    private func timelineBody(
        for content: TimelineItemContent,
        message: MessageContent?,
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
            return message.body
        }

        switch content {
        case let .msgLike(msgLike):
            switch msgLike.kind {
            case .redacted:
                return "Message removed"
            case let .sticker(body, _, _):
                return body
            case let .poll(question, _, _, _, _, _, _):
                return question
            case .unableToDecrypt:
                return "Unable to decrypt message"
            case .message:
                return ""
            case .other, .liveLocation:
                return "Unsupported event"
            }
        case .callInvite:
            return "Call invite"
        case .rtcNotification:
            return "Call update"
        case let .roomMembership(userId, userDisplayName, change, _):
            return membershipPreview(userID: userId, displayName: userDisplayName ?? userId, change: change)
        case let .profileChange(displayName, _, _, _):
            return displayName.map { "Profile changed: \($0)" } ?? "Profile changed"
        case let .state(stateKey, _):
            return "State update (\(stateKey))"
        case let .failedToParseMessageLike(eventType, _):
            return "Unsupported event: \(eventType)"
        case let .failedToParseState(eventType, _, _):
            return "Unsupported state: \(eventType)"
        }
    }

    private func messageLikeContent(from content: TimelineItemContent) -> MsgLikeContent? {
        guard case let .msgLike(value) = content else { return nil }
        return value
    }

    private func messageContent(from content: TimelineItemContent) -> MessageContent? {
        guard let messageLike = messageLikeContent(from: content), case let .message(value) = messageLike.kind else { return nil }
        return value
    }

    private func previewText(for content: TimelineItemContent, message: MessageContent?) -> String {
        if let status = timelineStatusDetails(for: content) {
            return status.renderedText
        }
        if let media = message.flatMap(timelineMediaAttachment(for:)) {
            return mediaPreviewText(for: media)
        }
        return timelineBody(for: content, message: message, status: nil, media: nil)
    }

    private func timelineStatusDetails(for content: TimelineItemContent) -> TimelineStatusDetails? {
        guard case let .roomMembership(userID, userDisplayName, change, _) = content else {
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

    private func timelineMediaAttachment(for message: MessageContent) -> TimelineMediaAttachment? {
        switch message.msgType {
        case let .image(content):
            return TimelineMediaAttachment(
                kind: .image,
                body: content.caption ?? content.filename,
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
                body: content.caption ?? content.filename,
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
                body: content.caption ?? content.filename,
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
                body: content.caption ?? content.filename,
                filename: content.filename,
                sourceURL: content.source.url(),
                sourceJSON: content.source.toJson(),
                mimeType: content.info?.mimetype,
                thumbnailSourceURL: content.info?.thumbnailSource?.url(),
                thumbnailSourceJSON: content.info?.thumbnailSource?.toJson(),
                thumbnailMimeType: content.info?.thumbnailInfo?.mimetype,
                allowsDirectDownload: allowsDirectDownload(for: content.source)
            )
        case .text, .notice, .emote, .location, .other, .gallery:
            return nil
        }
    }

    private func allowsDirectDownload(for source: MediaSource) -> Bool {
        guard let unencryptedSource = try? MediaSource.fromUrl(url: source.url()) else { return false }
        return source.toJson() == unencryptedSource.toJson()
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
        senderDisplayName(for: event.senderProfile, fallback: event.sender)
    }

    private func senderDisplayName(for profile: ProfileDetails, fallback: String) -> String {
        switch profile {
        case let .ready(displayName, _, _, _, _):
            return displayName ?? fallback
        case .pending, .unavailable, .error:
            return fallback
        }
    }

    private func messagePreview(for event: EventTimelineItem) -> String {
        let content = event.content
        let message = messageContent(from: content)
        return previewText(for: content, message: message)
    }

    private func replyPreview(for details: InReplyToDetails) -> String? {
        switch details.event() {
        case let .ready(content, sender, senderProfile, _, _):
            let body = previewText(for: content, message: messageContent(from: content))
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

        for chunkStart in stride(from: 0, to: roomIDsToSubscribe.count, by: Constants.backgroundSubscriptionBatchSize) {
            let chunk = Array(roomIDsToSubscribe[chunkStart..<min(chunkStart + Constants.backgroundSubscriptionBatchSize, roomIDsToSubscribe.count)])
            do {
                try await roomListService.subscribeToRooms(roomIds: chunk.map(\.rawValue))
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
                await self.performBackgroundRoomSweep(reason: "periodic-sweep", forceResubscribe: false)
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
        await refreshSpaceHierarchyIfNeeded(force: forceResubscribe)
        await publishRoomListSnapshot()
    }

    private func ensureBackgroundRoomInfoSubscriptions(for roomIDs: [RoomIdentifier]) async {
        for roomID in roomIDs where roomInfoSubscriptions[roomID] == nil {
            let roomItem: Room
            do {
                if let existing = roomItemsByID[roomID] {
                    roomItem = existing
                } else if let roomListService {
                    roomItem = try roomListService.room(roomId: roomID.rawValue)
                } else {
                    continue
                }

                let room = roomItem
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
