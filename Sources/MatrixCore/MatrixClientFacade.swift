import Foundation

public protocol MatrixClientFacade: Sendable {
    func bootstrapIfNeeded() async
    func sessionStateStream() async -> AsyncStream<ClientSessionState>
    func accountSummaries() async -> [AccountSummary]
    func allKnownRoomSummaries(for accountID: AccountIdentifier) async -> [RoomSummary]
    func spaceSummaries(for accountID: AccountIdentifier) async -> [SpaceSummary]
    func roomListStream(for accountID: AccountIdentifier, spaceID: SpaceIdentifier?) async -> AsyncStream<[RoomSummary]>
    func timelineStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<[TimelineItem]>
    func timelineHistoryStatusStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<TimelineHistoryStatus>
    func paginateOlderHistory(in roomID: RoomIdentifier, accountID: AccountIdentifier) async
    func mediaStateStream(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> AsyncStream<[String: TimelineMediaLoadState]>
    func mediaWorkerStateStream(for accountID: AccountIdentifier) async -> AsyncStream<[MediaDownloadWorkerSnapshot]>
    func notificationEventStream() async -> AsyncStream<RoomNotificationEvent>
    func verificationStateStream(for accountID: AccountIdentifier) async -> AsyncStream<VerificationSnapshot>
    func roomDetails(for accountID: AccountIdentifier, roomID: RoomIdentifier) async -> RoomDetails?
    func prepareMedia(_ item: TimelineItem, in accountID: AccountIdentifier, prefetchOriginal: Bool) async
    func resolveOriginalMediaURL(for item: TimelineItem, in accountID: AccountIdentifier) async -> URL?
    func resolveReceiptAvatarFileURL(for receipt: ReadReceipt, in accountID: AccountIdentifier) async -> URL?
    func requestVerification(for accountID: AccountIdentifier) async
    func startSasVerification(for accountID: AccountIdentifier) async
    func approveVerification(for accountID: AccountIdentifier) async
    func declineVerification(for accountID: AccountIdentifier) async
    func cancelVerification(for accountID: AccountIdentifier) async
    func markRoomAsRead(_ roomID: RoomIdentifier, accountID: AccountIdentifier) async
    func joinRoom(_ roomID: RoomIdentifier, accountID: AccountIdentifier) async throws
    func sendMessage(_ body: String, in roomID: RoomIdentifier, accountID: AccountIdentifier) async throws
    func sendMedia(_ attachment: OutgoingMediaAttachment, in roomID: RoomIdentifier, accountID: AccountIdentifier) async throws
    func setActiveAccount(_ accountID: AccountIdentifier?) async
    func queueDiagnostics() async -> [SendQueueSnapshot]
    func login(serverNameOrURL: String?, username: String, password: String) async
    func addAccount(serverNameOrURL: String?, username: String, password: String) async throws -> AccountSummary
    func removeAccount(_ accountID: AccountIdentifier) async throws
}
