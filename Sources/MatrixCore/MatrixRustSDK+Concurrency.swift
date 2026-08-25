import Foundation

#if canImport(MatrixRustSDK)
@preconcurrency import MatrixRustSDK

extension Client: @retroactive @unchecked Sendable {}
extension SyncService: @retroactive @unchecked Sendable {}
extension RoomListService: @retroactive @unchecked Sendable {}
extension RoomList: @retroactive @unchecked Sendable {}
extension Room: @retroactive @unchecked Sendable {}
extension Timeline: @retroactive @unchecked Sendable {}
extension Encryption: @retroactive @unchecked Sendable {}
extension TaskHandle: @retroactive @unchecked Sendable {}
extension HomeserverLoginDetails: @retroactive @unchecked Sendable {}
extension EventTimelineItem: @retroactive @unchecked Sendable {}
extension TimelineDiff: @retroactive @unchecked Sendable {}
extension SessionVerificationController: @retroactive @unchecked Sendable {}
extension SessionVerificationData: @retroactive @unchecked Sendable {}
extension SessionVerificationEmoji: @retroactive @unchecked Sendable {}
extension VerificationState: @retroactive @unchecked Sendable {}
extension SendAttachmentJoinHandle: @retroactive @unchecked Sendable {}
#endif
