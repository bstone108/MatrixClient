import Foundation

public struct SavedSessionRecord: Equatable, Hashable, Sendable {
    public let accountID: String
    public let userID: String
    public let homeserverURL: String

    public init(accountID: String, userID: String, homeserverURL: String) {
        self.accountID = accountID
        self.userID = userID
        self.homeserverURL = homeserverURL
    }
}

public enum SavedSessionFailureKind: Equatable, Sendable {
    case transient
    case invalid
}

public enum SavedSessionRestoreFailure: Error, Equatable, Sendable {
    case unreachableHomeserver
    case timedOut
    case corruptSession
    case unauthorized
}

public struct SavedSessionStartupPlan: Equatable, Sendable {
    public let immediateState: ClientSessionState
    public let summaries: [AccountSummary]
    public let startBackgroundReconnect: Bool
    public let retainPersistedSessions: Bool

    public init(
        immediateState: ClientSessionState,
        summaries: [AccountSummary],
        startBackgroundReconnect: Bool,
        retainPersistedSessions: Bool
    ) {
        self.immediateState = immediateState
        self.summaries = summaries
        self.startBackgroundReconnect = startBackgroundReconnect
        self.retainPersistedSessions = retainPersistedSessions
    }
}

public struct SavedSessionAttemptOutcome: Equatable, Sendable {
    public let nextState: ClientSessionState
    public let stillPendingAccountIDs: [String]
    public let removedAccountIDs: [String]
    public let retryDelay: TimeInterval?
    public let retainRemainingPersistedSessions: Bool
}

public enum SavedSessionRestorePolicy: Sendable {
    public static let reconnectingMessage = "Waiting for homeserver…"
    public static let maxRetryDelay: TimeInterval = 30
    public static let retrySchedule: [TimeInterval] = [0, 2, 5, 15, 30]

    public static func accountSummary(from record: SavedSessionRecord) -> AccountSummary {
        let homeserver = URL(string: record.homeserverURL) ?? URL(string: "https://invalid.local")!
        return AccountSummary(
            accountID: AccountIdentifier(rawValue: record.accountID),
            displayName: record.userID,
            userID: record.userID,
            homeserver: homeserver,
            avatarSymbolName: "person.crop.circle.fill"
        )
    }

    /// Computed from local persisted records only. Must not wait on the network.
    public static func startupPlan(persistedSessions: [SavedSessionRecord]) -> SavedSessionStartupPlan {
        guard !persistedSessions.isEmpty else {
            return SavedSessionStartupPlan(
                immediateState: .signedOut(message: nil),
                summaries: [],
                startBackgroundReconnect: false,
                retainPersistedSessions: false
            )
        }
        return SavedSessionStartupPlan(
            immediateState: .reconnecting(message: reconnectingMessage),
            summaries: persistedSessions.map(accountSummary(from:)),
            startBackgroundReconnect: true,
            retainPersistedSessions: true
        )
    }

    public static func classify(_ error: Error) -> SavedSessionFailureKind {
        if let failure = error as? SavedSessionRestoreFailure {
            switch failure {
            case .unreachableHomeserver, .timedOut:
                return .transient
            case .corruptSession, .unauthorized:
                return .invalid
            }
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed, .secureConnectionFailed:
                return .transient
            default:
                return .transient
            }
        }
        let text = error.localizedDescription.lowercased()
        if text.contains("unknown_token")
            || text.contains("unauthorized")
            || text.contains("corrupt")
            || text.contains("keychain")
            || text.contains("decode") {
            return .invalid
        }
        return .transient
    }

    public static func shouldRemovePersistedSession(for error: Error) -> Bool {
        classify(error) == .invalid
    }

    public static func retryDelay(attempt: Int) -> TimeInterval {
        if attempt < 0 { return 0 }
        if attempt >= retrySchedule.count { return maxRetryDelay }
        return retrySchedule[attempt]
    }

    public static func outcomeAfterAttempt(
        pending: [SavedSessionRecord],
        results: [String: Result<Void, SavedSessionRestoreFailure>],
        alreadyRestoredCount: Int,
        attempt: Int
    ) -> SavedSessionAttemptOutcome {
        var stillPending: [SavedSessionRecord] = []
        var removed: [String] = []
        var newlyRestored = 0

        for record in pending {
            guard let result = results[record.accountID] else {
                stillPending.append(record)
                continue
            }
            switch result {
            case .success:
                newlyRestored += 1
            case let .failure(error):
                if shouldRemovePersistedSession(for: error) {
                    removed.append(record.accountID)
                } else {
                    stillPending.append(record)
                }
            }
        }

        let restoredCount = alreadyRestoredCount + newlyRestored
        if stillPending.isEmpty {
            if restoredCount > 0 {
                return SavedSessionAttemptOutcome(
                    nextState: .connected,
                    stillPendingAccountIDs: [],
                    removedAccountIDs: removed,
                    retryDelay: nil,
                    retainRemainingPersistedSessions: true
                )
            }
            return SavedSessionAttemptOutcome(
                nextState: .signedOut(message: "Saved session could not be restored."),
                stillPendingAccountIDs: [],
                removedAccountIDs: removed,
                retryDelay: nil,
                retainRemainingPersistedSessions: false
            )
        }

        return SavedSessionAttemptOutcome(
            nextState: .reconnecting(message: reconnectingMessage),
            stillPendingAccountIDs: stillPending.map(\.accountID),
            removedAccountIDs: removed,
            retryDelay: retryDelay(attempt: attempt),
            retainRemainingPersistedSessions: true
        )
    }
}
