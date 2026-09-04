import Diagnostics
import Foundation
import Persistence

#if canImport(MatrixRustSDK)
@preconcurrency import MatrixRustSDK
#endif

public actor MatrixClientService: MatrixClientFacade {
    private let diagnostics: DiagnosticsService
    private let database: AppDatabase
    private let sessionStore: StoredSessionStore
    private let sessionStateBroadcaster = AsyncBroadcaster<ClientSessionState>(initialValue: .launching)
    private let notificationBroadcaster = AsyncBroadcaster<RoomNotificationEvent>()

    private var sessions: [AccountIdentifier: AccountSessionActor] = [:]
    private var accountOrder: [AccountIdentifier] = []
    private var sessionNotificationTasks: [AccountIdentifier: Task<Void, Never>] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var cachedAccountSummaries: [AccountIdentifier: AccountSummary] = [:]
    private var offlineRoomSummaries: [AccountIdentifier: [RoomSummary]] = [:]
    private var offlineTimelines: [AccountIdentifier: [RoomIdentifier: [TimelineItem]]] = [:]
    private var bootstrapped = false

    public init(database: AppDatabase, diagnostics: DiagnosticsService) {
        self.database = database
        self.diagnostics = diagnostics
        self.sessionStore = StoredSessionStore(rootURL: database.paths.applicationSupportURL)
    }

    public func bootstrapIfNeeded() async {
        guard !bootstrapped else { return }
        bootstrapped = true

        do {
            let persistedSessions = try sessionStore.loadPersistedSessions()
            let records = persistedSessions.map {
                SavedSessionRecord(accountID: $0.accountID, userID: $0.userID, homeserverURL: $0.homeserverURL)
            }
            let plan = SavedSessionRestorePolicy.startupPlan(persistedSessions: records)
            cachedAccountSummaries = Dictionary(uniqueKeysWithValues: plan.summaries.map { ($0.accountID, $0) })
            accountOrder = plan.summaries.map(\.accountID)
            sessionStateBroadcaster.yield(plan.immediateState)
            await loadOfflineWorkspace(from: persistedSessions)
            if plan.startBackgroundReconnect {
                sessionStateBroadcaster.yield(plan.immediateState)
            }

            guard plan.startBackgroundReconnect else { return }
            startBackgroundReconnect(persistedSessions, startingAttempt: 0)
        } catch {
            await diagnostics.record(.error, category: "Auth", message: "Failed to read persisted sessions", metadata: [
                "error": userVisibleErrorMessage(error)
            ])
            sessionStateBroadcaster.yield(.signedOut(message: userVisibleErrorMessage(error)))
        }
    }

    public func sessionStateStream() async -> AsyncStream<ClientSessionState> {
        sessionStateBroadcaster.stream()
    }

    public func login(serverNameOrURL: String?, username: String, password: String) async {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty, !normalizedPassword.isEmpty else {
            sessionStateBroadcaster.yield(.signedOut(message: "Enter a username and password."))
            return
        }

        guard let resolvedServerInput = resolveServerNameOrURL(serverNameOrURL, username: normalizedUsername) else {
            sessionStateBroadcaster.yield(.signedOut(message: "Enter a server name, homeserver URL, or a full Matrix user ID."))
            return
        }

        sessionStateBroadcaster.yield(.signingIn(message: "Connecting to \(resolvedServerInput)…"))
        do {
            _ = try await createSession(
                serverNameOrURL: resolvedServerInput,
                username: normalizedUsername,
                password: normalizedPassword,
            )
            sessionStateBroadcaster.yield(.connected)
        } catch {
            await diagnostics.record(.error, category: "Auth", message: "Failed to sign into homeserver", metadata: [
                "server": resolvedServerInput,
                "error": userVisibleErrorMessage(error)
            ])
            sessionStateBroadcaster.yield(.signedOut(message: userVisibleErrorMessage(error)))
        }
    }

    public func addAccount(serverNameOrURL: String?, username: String, password: String) async throws -> AccountSummary {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty, !normalizedPassword.isEmpty else {
            throw MatrixClientServiceError.invalidCredentials
        }

        guard let resolvedServerInput = resolveServerNameOrURL(serverNameOrURL, username: normalizedUsername) else {
            throw MatrixClientServiceError.invalidServerInput
        }

        do {
            let session = try await createSession(
                serverNameOrURL: resolvedServerInput,
                username: normalizedUsername,
                password: normalizedPassword
            )
            sessionStateBroadcaster.yield(.connected)
            return session.summary
        } catch {
            await diagnostics.record(.error, category: "Auth", message: "Failed to add homeserver account", metadata: [
                "server": resolvedServerInput,
                "error": userVisibleErrorMessage(error)
            ])
            throw error
        }
    }

    public func removeAccount(_ accountID: AccountIdentifier) async throws {
        reconnectTask?.cancel()
        reconnectTask = nil
        cachedAccountSummaries.removeValue(forKey: accountID)
        offlineRoomSummaries.removeValue(forKey: accountID)
        offlineTimelines.removeValue(forKey: accountID)
        guard let session = sessions[accountID] else {
            do {
                try sessionStore.remove(accountID: accountID.rawValue)
            } catch {
                await diagnostics.record(.error, category: "Auth", message: "Failed to remove persisted session", metadata: [
                    "accountID": accountID.rawValue,
                    "error": userVisibleErrorMessage(error)
                ])
                throw error
            }
            accountOrder.removeAll { $0 == accountID }
            yieldStateAfterAccountRemoval()
            startBackgroundReconnectIfNeeded()
            return
        }

        sessionNotificationTasks[accountID]?.cancel()
        sessionNotificationTasks.removeValue(forKey: accountID)
        await session.shutdown(logoutRemote: true)

        do {
            try sessionStore.remove(accountID: accountID.rawValue)
        } catch {
            await diagnostics.record(.error, category: "Auth", message: "Failed to remove persisted session", metadata: [
                "accountID": accountID.rawValue,
                "error": userVisibleErrorMessage(error)
            ])
            throw error
        }

        sessions.removeValue(forKey: accountID)
        accountOrder.removeAll { $0 == accountID }

        yieldStateAfterAccountRemoval()
        startBackgroundReconnectIfNeeded()
    }

    public func accountSummaries() async -> [AccountSummary] {
        accountOrder.compactMap { sessions[$0]?.summary ?? cachedAccountSummaries[$0] }
    }

    public func allKnownRoomSummaries(for accountID: AccountIdentifier) async -> [RoomSummary] {
        if let session = sessions[accountID] {
            return await session.allKnownRoomSummaries()
        }
        return offlineRoomSummaries[accountID, default: []]
    }

    public func spaceSummaries(for accountID: AccountIdentifier) async -> [SpaceSummary] {
        guard let session = sessions[accountID] else { return [] }
        return await session.spaces()
    }

    public func roomListStream(for accountID: AccountIdentifier, spaceID: SpaceIdentifier?) async -> AsyncStream<[RoomSummary]> {
        if let session = sessions[accountID] {
            return await session.roomListStream(spaceID: spaceID)
        }
        let cached = offlineRoomSummaries[accountID, default: []]
        return AsyncStream { continuation in
            continuation.yield(cached)
            continuation.finish()
        }
    }

    public func timelineStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<[TimelineItem]> {
        if let session = sessions[accountID] {
            return await session.timelineStream(roomID: roomID)
        }
        let cached = offlineTimelines[accountID]?[roomID] ?? []
        return AsyncStream { continuation in
            continuation.yield(cached)
            continuation.finish()
        }
    }

    public func timelineHistoryStatusStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<TimelineHistoryStatus> {
        guard let session = sessions[accountID] else { return AsyncStream { _ in } }
        return await session.timelineHistoryStatusStream(roomID: roomID)
    }

    public func paginateOlderHistory(in roomID: RoomIdentifier, accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        await session.paginateOlderHistory(roomID: roomID)
    }

    public func mediaStateStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<[String: TimelineMediaLoadState]> {
        guard let session = sessions[accountID] else { return AsyncStream { _ in } }
        return await session.mediaStateStream(roomID: roomID)
    }

    public func mediaWorkerStateStream(for accountID: AccountIdentifier) async -> AsyncStream<[MediaDownloadWorkerSnapshot]> {
        guard let session = sessions[accountID] else { return AsyncStream { _ in } }
        return await session.mediaWorkerStateStream()
    }

    public func notificationEventStream() async -> AsyncStream<RoomNotificationEvent> {
        notificationBroadcaster.stream()
    }

    public func verificationStateStream(for accountID: AccountIdentifier) async -> AsyncStream<VerificationSnapshot> {
        guard let session = sessions[accountID] else { return AsyncStream { _ in } }
        return await session.verificationStateStream()
    }

    public func roomDetails(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> RoomDetails? {
        guard let session = sessions[accountID] else { return nil }
        return await session.roomDetails(roomID: roomID)
    }

    public func prepareMedia(_ item: TimelineItem, in accountID: AccountIdentifier, prefetchOriginal: Bool) async {
        guard let session = sessions[accountID] else { return }
        await session.prepareMedia(item, prefetchOriginal: prefetchOriginal)
    }

    public func resolveOriginalMediaURL(for item: TimelineItem, in accountID: AccountIdentifier) async -> URL? {
        guard let session = sessions[accountID] else { return nil }
        return await session.resolveOriginalMediaURL(for: item)
    }

    public func resolveReceiptAvatarFileURL(for receipt: ReadReceipt, in accountID: AccountIdentifier) async -> URL? {
        guard let session = sessions[accountID] else { return nil }
        return await session.resolveReceiptAvatarFileURL(for: receipt)
    }

    public func requestVerification(for accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        do {
            try await session.requestVerification()
        } catch {
            await diagnostics.record(.error, category: "Verification", message: "Failed to request verification", metadata: [
                "accountID": accountID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    public func startSasVerification(for accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        do {
            try await session.startSasVerification()
        } catch {
            await diagnostics.record(.error, category: "Verification", message: "Failed to start SAS verification", metadata: [
                "accountID": accountID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    public func approveVerification(for accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        do {
            try await session.approveVerification()
        } catch {
            await diagnostics.record(.error, category: "Verification", message: "Failed to approve verification", metadata: [
                "accountID": accountID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    public func declineVerification(for accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        do {
            try await session.declineVerification()
        } catch {
            await diagnostics.record(.error, category: "Verification", message: "Failed to decline verification", metadata: [
                "accountID": accountID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    public func cancelVerification(for accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        do {
            try await session.cancelVerification()
        } catch {
            await diagnostics.record(.error, category: "Verification", message: "Failed to cancel verification", metadata: [
                "accountID": accountID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    public func markRoomAsRead(_ roomID: RoomIdentifier, upTo eventID: String, accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        await session.markRoomAsRead(roomID, upTo: eventID)
    }

    public func joinRoom(_ roomID: RoomIdentifier, accountID: AccountIdentifier) async throws {
        guard let session = sessions[accountID] else { return }
        try await session.joinRoom(roomID)
    }

    public func sendMessage(_ body: String, in roomID: RoomIdentifier, accountID: AccountIdentifier) async throws {
        guard let session = sessions[accountID] else {
            throw MatrixSendError.missingSelection
        }
        do {
            try await session.sendMessage(body, roomID: roomID)
        } catch {
            await diagnostics.record(.error, category: "Timeline", message: "Failed to send message", metadata: [
                "roomID": roomID.rawValue,
                "accountID": accountID.rawValue,
                "error": error.localizedDescription
            ])
            throw error
        }
    }

    public func sendMedia(_ attachment: OutgoingMediaAttachment, in roomID: RoomIdentifier, accountID: AccountIdentifier) async throws {
        guard let session = sessions[accountID] else {
            throw MatrixSendError.missingSelection
        }
        do {
            try await session.sendMedia(attachment, roomID: roomID)
        } catch {
            await diagnostics.record(.error, category: "Timeline", message: "Failed to send file", metadata: [
                "roomID": roomID.rawValue,
                "accountID": accountID.rawValue,
                "filename": attachment.filename,
                "mimeType": attachment.mimeType,
                "error": error.localizedDescription
            ])
            throw error
        }
    }

    public func setActiveAccount(_ accountID: AccountIdentifier?) async {
        for (sessionID, session) in sessions {
            await session.setForeground(sessionID == accountID)
        }
    }

    public func queueDiagnostics() async -> [SendQueueSnapshot] {
        var result: [SendQueueSnapshot] = []
        for session in sessions.values {
            result.append(contentsOf: await session.queueDiagnostics())
        }
        return result.sorted { $0.transactionID < $1.transactionID }
    }

    private func resolveServerNameOrURL(_ serverNameOrURL: String?, username: String) -> String? {
        let trimmedServer = serverNameOrURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedServer.isEmpty {
            return trimmedServer
        }

        guard let separatorIndex = username.lastIndex(of: ":") else {
            return nil
        }
        let domain = username[username.index(after: separatorIndex)...]
        return domain.isEmpty ? nil : String(domain)
    }

    private func userVisibleErrorMessage(_ error: Error) -> String {
        #if canImport(MatrixRustSDK)
        if let buildError = error as? ClientBuildError {
            switch buildError {
            case let .InvalidServerName(message),
                 let .ServerUnreachable(message),
                 let .WellKnownLookupFailed(message),
                 let .WellKnownDeserializationError(message),
                 let .SlidingSync(message),
                 let .SlidingSyncVersion(message),
                 let .Sdk(message),
                 let .EventCache(message),
                 let .InvalidRawKey(message):
                return message
            case let .Generic(message):
                return message
            }
        }
        if let clientError = error as? ClientError, case let .Generic(msg, _) = clientError {
            return msg
        }
        #endif

        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }

    @discardableResult
    private func createSession(
        serverNameOrURL: String,
        username: String,
        password: String
    ) async throws -> AccountSessionActor {
        reconnectTask?.cancel()
        reconnectTask = nil
        let session = try await AccountSessionActor.login(
            serverNameOrURL: serverNameOrURL,
            username: username,
            password: password,
            sessionStore: sessionStore,
            applicationSupportURL: database.paths.applicationSupportURL,
            database: database,
            diagnostics: diagnostics
        )
        if let existing = sessions[session.summary.accountID] {
            sessionNotificationTasks[session.summary.accountID]?.cancel()
            sessionNotificationTasks.removeValue(forKey: session.summary.accountID)
            await existing.shutdown(logoutRemote: false)
        }

        sessions[session.summary.accountID] = session
        attachNotificationStream(for: session)
        if !accountOrder.contains(session.summary.accountID) {
            accountOrder.append(session.summary.accountID)
            accountOrder.sort { $0.rawValue < $1.rawValue }
        }

        cachedAccountSummaries[session.summary.accountID] = session.summary
        Task { [diagnostics] in
            do {
                try await session.bootstrapIfNeeded()
            } catch {
                await diagnostics.record(.error, category: "Sync", message: "Signed in, but initial synchronization failed", metadata: [
                    "accountID": session.summary.accountID.rawValue,
                    "error": error.localizedDescription
                ])
            }
        }
        startBackgroundReconnectIfNeeded()
        return session
    }

    private func yieldStateAfterAccountRemoval() {
        if !sessions.isEmpty {
            sessionStateBroadcaster.yield(.connected)
        } else if !cachedAccountSummaries.isEmpty {
            sessionStateBroadcaster.yield(.reconnecting(message: SavedSessionRestorePolicy.reconnectingMessage))
        } else {
            sessionStateBroadcaster.yield(.signedOut(message: nil))
        }
    }

    private func startBackgroundReconnectIfNeeded() {
        guard let persistedSessions = try? sessionStore.loadPersistedSessions() else { return }
        let pending = persistedSessions.filter { sessions[AccountIdentifier(rawValue: $0.accountID)] == nil }
        guard !pending.isEmpty else { return }
        startBackgroundReconnect(pending, startingAttempt: 0)
    }

    private func startBackgroundReconnect(_ persistedSessions: [PersistedAccountSession], startingAttempt: Int) {
        reconnectTask?.cancel()
        reconnectTask = Task {
            await self.reconnectPersistedSessions(persistedSessions, startingAttempt: startingAttempt)
        }
    }

    private func loadOfflineWorkspace(from persistedSessions: [PersistedAccountSession]) async {
        for persisted in persistedSessions {
            let accountID = AccountIdentifier(rawValue: persisted.accountID)
            let roomRepo = PersistedRoomSummaryRepository(
                database: database,
                diagnostics: diagnostics,
                accountID: persisted.accountID
            )
            let timelineRepo = PersistedTimelineRepository(
                database: database,
                diagnostics: diagnostics,
                accountID: persisted.accountID
            )
            do {
                let roomPayloads = try await roomRepo.fetchAll()
                let rooms = roomPayloads.compactMap { PersistedWorkspaceCodec.decodeRoomSummary(from: $0.payload) }
                    .sorted { $0.timestamp > $1.timestamp }
                offlineRoomSummaries[accountID] = rooms

                var timelines: [RoomIdentifier: [TimelineItem]] = [:]
                for room in rooms {
                    let records = try await timelineRepo.fetch(roomID: room.roomID.rawValue)
                    let items = records.compactMap { PersistedWorkspaceCodec.decodeTimelineItem(from: $0.payload) }
                    if !items.isEmpty {
                        timelines[room.roomID] = TimelineItemReconciler.deduplicated(items)
                    }
                }
                offlineTimelines[accountID] = timelines
            } catch {
                await diagnostics.record(.error, category: "Auth", message: "Failed to load offline workspace cache", metadata: [
                    "accountID": persisted.accountID,
                    "error": error.localizedDescription
                ])
            }
        }
    }

    private func reconnectPersistedSessions(_ persistedSessions: [PersistedAccountSession], startingAttempt: Int) async {
        var pending = persistedSessions.filter { sessions[AccountIdentifier(rawValue: $0.accountID)] == nil }
        var attempt = startingAttempt
        var restoredCount = sessions.count

        while !Task.isCancelled, !pending.isEmpty {
            var results: [String: Result<Void, SavedSessionRestoreFailure>] = [:]
            var nextPending: [PersistedAccountSession] = []

            for persisted in pending {
                if Task.isCancelled { return }
                let accountID = AccountIdentifier(rawValue: persisted.accountID)
                if sessions[accountID] != nil {
                    results[persisted.accountID] = .success(())
                    continue
                }
                do {
                    let session = try await AccountSessionActor.restore(
                        persistedSession: persisted,
                        sessionStore: sessionStore,
                        applicationSupportURL: database.paths.applicationSupportURL,
                        database: database,
                        diagnostics: diagnostics
                    )
                    try await session.bootstrapIfNeeded()
                    if Task.isCancelled || sessions[session.summary.accountID] != nil {
                        await session.shutdown(logoutRemote: false)
                        if sessions[session.summary.accountID] != nil {
                            results[persisted.accountID] = .success(())
                            continue
                        }
                        return
                    }
                    sessions[session.summary.accountID] = session
                    cachedAccountSummaries[session.summary.accountID] = session.summary
                    attachNotificationStream(for: session)
                    results[persisted.accountID] = .success(())
                } catch {
                    let kind = SavedSessionRestorePolicy.classify(error)
                    await diagnostics.record(.error, category: "Auth", message: "Failed to restore session", metadata: [
                        "accountID": persisted.accountID,
                        "kind": kind == .transient ? "transient" : "invalid",
                        "error": userVisibleErrorMessage(error)
                    ])
                    if SavedSessionRestorePolicy.shouldRemovePersistedSession(for: error) {
                        try? sessionStore.remove(accountID: persisted.accountID)
                        cachedAccountSummaries.removeValue(forKey: AccountIdentifier(rawValue: persisted.accountID))
                        accountOrder.removeAll { $0.rawValue == persisted.accountID }
                        results[persisted.accountID] = .failure(.corruptSession)
                    } else {
                        results[persisted.accountID] = .failure(.unreachableHomeserver)
                        nextPending.append(persisted)
                    }
                }
            }

            let records = pending.map {
                SavedSessionRecord(accountID: $0.accountID, userID: $0.userID, homeserverURL: $0.homeserverURL)
            }
            let outcome = SavedSessionRestorePolicy.outcomeAfterAttempt(
                pending: records,
                results: results,
                alreadyRestoredCount: restoredCount,
                attempt: attempt
            )
            restoredCount = sessions.count
            pending = nextPending
            accountOrder = Array(Set(accountOrder + sessions.keys)).sorted { $0.rawValue < $1.rawValue }
            sessionStateBroadcaster.yield(outcome.nextState)

            if outcome.retryDelay == nil {
                return
            }
            let delay = outcome.retryDelay ?? SavedSessionRestorePolicy.maxRetryDelay
            attempt += 1
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func attachNotificationStream(for session: AccountSessionActor) {
        let accountID = session.summary.accountID
        sessionNotificationTasks[accountID]?.cancel()
        let broadcaster = notificationBroadcaster
        sessionNotificationTasks[accountID] = Task {
            let stream = await session.notificationEventStream()
            for await event in stream {
                broadcaster.yield(event)
            }
        }
    }
}

private enum MatrixClientServiceError: LocalizedError {
    case invalidCredentials
    case invalidServerInput

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Enter a username and password."
        case .invalidServerInput:
            return "Enter a server name, homeserver URL, or a full Matrix user ID."
        }
    }
}
