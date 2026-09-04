import AppKit
import Diagnostics
import Foundation
import MatrixCore
import MediaKit

@MainActor
final class WindowFrameTestVideoEngine: VideoPlaybackEngine {
    var displayName: String { "test" }

    func makePlayerView(for url: URL) -> NSView {
        NSView(frame: .zero)
    }
}

final class WindowFrameTestMatrixClient: MatrixClientFacade, @unchecked Sendable {
    func bootstrapIfNeeded() async {}

    func sessionStateStream() async -> AsyncStream<ClientSessionState> {
        AsyncStream { continuation in
            continuation.yield(.signedOut(message: nil))
            continuation.finish()
        }
    }

    func accountSummaries() async -> [AccountSummary] { [] }
    func allKnownRoomSummaries(for accountID: AccountIdentifier) async -> [RoomSummary] { [] }
    func spaceSummaries(for accountID: AccountIdentifier) async -> [SpaceSummary] { [] }

    func roomListStream(for accountID: AccountIdentifier, spaceID: SpaceIdentifier?) async -> AsyncStream<[RoomSummary]> {
        AsyncStream { $0.finish() }
    }

    func timelineStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<[TimelineItem]> {
        AsyncStream { $0.finish() }
    }

    func timelineHistoryStatusStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<TimelineHistoryStatus> {
        AsyncStream { $0.finish() }
    }

    func paginateOlderHistory(in roomID: RoomIdentifier, accountID: AccountIdentifier) async {}

    func mediaStateStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<[String: TimelineMediaLoadState]> {
        AsyncStream { $0.finish() }
    }

    func mediaWorkerStateStream(for accountID: AccountIdentifier) async -> AsyncStream<[MediaDownloadWorkerSnapshot]> {
        AsyncStream { $0.finish() }
    }

    func notificationEventStream() async -> AsyncStream<RoomNotificationEvent> {
        AsyncStream { $0.finish() }
    }

    func verificationStateStream(for accountID: AccountIdentifier) async -> AsyncStream<VerificationSnapshot> {
        AsyncStream { $0.finish() }
    }

    func roomDetails(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> RoomDetails? { nil }
    func prepareMedia(_ item: TimelineItem, in accountID: AccountIdentifier, prefetchOriginal: Bool) async {}
    func resolveOriginalMediaURL(for item: TimelineItem, in accountID: AccountIdentifier) async -> URL? { nil }
    func resolveReceiptAvatarFileURL(for receipt: ReadReceipt, in accountID: AccountIdentifier) async -> URL? { nil }
    func requestVerification(for accountID: AccountIdentifier) async {}
    func startSasVerification(for accountID: AccountIdentifier) async {}
    func approveVerification(for accountID: AccountIdentifier) async {}
    func declineVerification(for accountID: AccountIdentifier) async {}
    func cancelVerification(for accountID: AccountIdentifier) async {}
    func markRoomAsRead(_ roomID: RoomIdentifier, upTo eventID: String, accountID: AccountIdentifier) async {}
    func joinRoom(_ roomID: RoomIdentifier, accountID: AccountIdentifier) async throws {}
    func sendMessage(_ body: String, in roomID: RoomIdentifier, accountID: AccountIdentifier) async throws {}
    func sendMedia(_ attachment: OutgoingMediaAttachment, in roomID: RoomIdentifier, accountID: AccountIdentifier) async throws {}
    func setActiveAccount(_ accountID: AccountIdentifier?) async {}
    func queueDiagnostics() async -> [SendQueueSnapshot] { [] }
    func login(serverNameOrURL: String?, username: String, password: String) async {}
    func addAccount(serverNameOrURL: String?, username: String, password: String) async throws -> AccountSummary {
        AccountSummary(
            accountID: AccountIdentifier(rawValue: "test"),
            displayName: "test",
            userID: "@test:example.org",
            homeserver: URL(string: "https://example.org")!,
            avatarSymbolName: "person"
        )
    }
    func removeAccount(_ accountID: AccountIdentifier) async throws {}
}
