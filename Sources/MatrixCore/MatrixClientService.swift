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
    private var bootstrapped = false

    public init(database: AppDatabase, diagnostics: DiagnosticsService) {
        self.database = database
        self.diagnostics = diagnostics
        self.sessionStore = StoredSessionStore(rootURL: database.paths.applicationSupportURL)
    }

    public func bootstrapIfNeeded() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        sessionStateBroadcaster.yield(.restoring(message: "Restoring saved session…"))

        do {
            let persistedSessions = try sessionStore.loadPersistedSessions()
            guard !persistedSessions.isEmpty else {
                sessionStateBroadcaster.yield(.signedOut(message: nil))
                return
            }

            for persistedSession in persistedSessions {
                do {
                    let session = try await AccountSessionActor.restore(
                        persistedSession: persistedSession,
                        sessionStore: sessionStore,
                        applicationSupportURL: database.paths.applicationSupportURL,
                        database: database,
                        diagnostics: diagnostics
                    )
                    try await session.bootstrapIfNeeded()
                    sessions[session.summary.accountID] = session
                    accountOrder.append(session.summary.accountID)
                    attachNotificationStream(for: session)
                } catch {
                    try? sessionStore.remove(accountID: persistedSession.accountID)
                    await diagnostics.record(.error, category: "Auth", message: "Failed to restore session", metadata: [
                        "accountID": persistedSession.accountID,
                        "error": userVisibleErrorMessage(error)
                    ])
                }
            }

            accountOrder = Array(Set(accountOrder)).sorted { $0.rawValue < $1.rawValue }
            sessionStateBroadcaster.yield(sessions.isEmpty ? .signedOut(message: "Saved session could not be restored.") : .connected)
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
        guard let session = sessions[accountID] else { return }

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

        if sessions.isEmpty {
            sessionStateBroadcaster.yield(.signedOut(message: nil))
        } else {
            sessionStateBroadcaster.yield(.connected)
        }
    }

    public func accountSummaries() async -> [AccountSummary] {
        accountOrder.compactMap { sessions[$0]?.summary }
    }

    public func allKnownRoomSummaries(for accountID: AccountIdentifier) async -> [RoomSummary] {
        guard let session = sessions[accountID] else { return [] }
        return await session.allKnownRoomSummaries()
    }

    public func spaceSummaries(for accountID: AccountIdentifier) async -> [SpaceSummary] {
        guard let session = sessions[accountID] else { return [] }
        return await session.spaces()
    }

    public func roomListStream(for accountID: AccountIdentifier, spaceID: SpaceIdentifier?) async -> AsyncStream<[RoomSummary]> {
        guard let session = sessions[accountID] else { return AsyncStream { _ in } }
        return await session.roomListStream(spaceID: spaceID)
    }

    public func timelineStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<[TimelineItem]> {
        guard let session = sessions[accountID] else { return AsyncStream { _ in } }
        return await session.timelineStream(roomID: roomID)
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

    public func markRoomAsRead(_ roomID: RoomIdentifier, accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        await session.markRoomAsRead(roomID)
    }

    public func joinRoom(_ roomID: RoomIdentifier, accountID: AccountIdentifier) async throws {
        guard let session = sessions[accountID] else { return }
        try await session.joinRoom(roomID)
    }

    public func sendMessage(_ body: String, in roomID: RoomIdentifier, accountID: AccountIdentifier) async {
        guard let session = sessions[accountID] else { return }
        do {
            try await session.sendMessage(body, roomID: roomID)
        } catch {
            await diagnostics.record(.error, category: "Timeline", message: "Failed to enqueue message", metadata: [
                "roomID": roomID.rawValue,
                "accountID": accountID.rawValue,
                "error": error.localizedDescription
            ])
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
        let session = try await AccountSessionActor.login(
            serverNameOrURL: serverNameOrURL,
            username: username,
            password: password,
            sessionStore: sessionStore,
            applicationSupportURL: database.paths.applicationSupportURL,
            database: database,
            diagnostics: diagnostics
        )
        try await session.bootstrapIfNeeded()

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
        return session
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
