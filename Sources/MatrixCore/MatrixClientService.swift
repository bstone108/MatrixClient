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

    private var sessions: [AccountIdentifier: AccountSessionActor] = [:]
    private var accountOrder: [AccountIdentifier] = []
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
            let session = try await AccountSessionActor.login(
                serverNameOrURL: resolvedServerInput,
                username: normalizedUsername,
                password: normalizedPassword,
                sessionStore: sessionStore,
                applicationSupportURL: database.paths.applicationSupportURL,
                database: database,
                diagnostics: diagnostics
            )
            try await session.bootstrapIfNeeded()
            sessions[session.summary.accountID] = session
            if !accountOrder.contains(session.summary.accountID) {
                accountOrder.append(session.summary.accountID)
                accountOrder.sort { $0.rawValue < $1.rawValue }
            }
            sessionStateBroadcaster.yield(.connected)
        } catch {
            await diagnostics.record(.error, category: "Auth", message: "Failed to sign into homeserver", metadata: [
                "server": resolvedServerInput,
                "error": userVisibleErrorMessage(error)
            ])
            sessionStateBroadcaster.yield(.signedOut(message: userVisibleErrorMessage(error)))
        }
    }

    public func accountSummaries() async -> [AccountSummary] {
        accountOrder.compactMap { sessions[$0]?.summary }
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
                 let .Generic(message):
                return message
            }
        }
        if let clientError = error as? ClientError, case let .Generic(msg) = clientError {
            return msg
        }
        if let roomListError = error as? RoomListError {
            switch roomListError {
            case let .SlidingSync(error),
                 let .InvalidRoomId(error),
                 let .InitializingTimeline(error),
                 let .EventCache(error):
                return error
            case let .UnknownList(listName):
                return "Unknown room list: \(listName)"
            case .InputCannotBeApplied:
                return "A room list update could not be applied."
            case let .RoomNotFound(roomName):
                return "Room not found: \(roomName)"
            case let .TimelineAlreadyExists(roomName):
                return "Timeline already exists for \(roomName)."
            case let .TimelineNotInitialized(roomName):
                return "Timeline not initialized for \(roomName)."
            case let .IncorrectRoomMembership(expected, actual):
                return "Incorrect room membership. Expected \(expected), got \(actual)."
            }
        }
        #endif

        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
