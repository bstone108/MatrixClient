import Foundation

public struct AccountIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct SpaceIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct RoomIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct EventTransactionIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    public init(rawValue: String = UUID().uuidString) { self.rawValue = rawValue }
}

public struct AccountSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: AccountIdentifier { accountID }
    public let accountID: AccountIdentifier
    public let displayName: String
    public let userID: String
    public let homeserver: URL
    public let avatarSymbolName: String

    public init(accountID: AccountIdentifier, displayName: String, userID: String, homeserver: URL, avatarSymbolName: String) {
        self.accountID = accountID
        self.displayName = displayName
        self.userID = userID
        self.homeserver = homeserver
        self.avatarSymbolName = avatarSymbolName
    }
}

public struct SpaceSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: SpaceIdentifier { spaceID }
    public let spaceID: SpaceIdentifier
    public let displayName: String
    public let unreadCount: Int
    public let roomIDs: [RoomIdentifier]

    public init(spaceID: SpaceIdentifier, displayName: String, unreadCount: Int, roomIDs: [RoomIdentifier]) {
        self.spaceID = spaceID
        self.displayName = displayName
        self.unreadCount = unreadCount
        self.roomIDs = roomIDs
    }
}

public struct RoomSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: RoomIdentifier { roomID }
    public let roomID: RoomIdentifier
    public let displayName: String
    public let topic: String
    public let lastMessagePreview: String
    public let timestamp: Date
    public let unreadCount: Int
    public let highlightCount: Int
    public let isDirect: Bool
    public let isEncrypted: Bool
    public let lastSenderDisplayName: String

    public init(
        roomID: RoomIdentifier,
        displayName: String,
        topic: String,
        lastMessagePreview: String,
        timestamp: Date,
        unreadCount: Int,
        highlightCount: Int,
        isDirect: Bool,
        isEncrypted: Bool,
        lastSenderDisplayName: String
    ) {
        self.roomID = roomID
        self.displayName = displayName
        self.topic = topic
        self.lastMessagePreview = lastMessagePreview
        self.timestamp = timestamp
        self.unreadCount = unreadCount
        self.highlightCount = highlightCount
        self.isDirect = isDirect
        self.isEncrypted = isEncrypted
        self.lastSenderDisplayName = lastSenderDisplayName
    }
}

public enum WorkspaceSettingsDestination: String, Codable, Sendable {
    case securityVerification

    public var title: String {
        switch self {
        case .securityVerification:
            return "Security / Verification"
        }
    }
}

public enum MediaDownloadWorkerKind: String, Codable, Sendable {
    case thumbnail
    case original

    public var title: String {
        switch self {
        case .thumbnail:
            return "Thumb"
        case .original:
            return "Orig"
        }
    }
}

public struct MediaDownloadWorkerSnapshot: Identifiable, Hashable, Codable, Sendable {
    public let workerID: String
    public let kind: MediaDownloadWorkerKind
    public let slot: Int
    public let label: String
    public let statusText: String
    public let pendingCount: Int
    public let roomID: String?
    public let itemID: String?

    public var id: String { workerID }

    public init(
        workerID: String,
        kind: MediaDownloadWorkerKind,
        slot: Int,
        label: String,
        statusText: String,
        pendingCount: Int,
        roomID: String?,
        itemID: String?
    ) {
        self.workerID = workerID
        self.kind = kind
        self.slot = slot
        self.label = label
        self.statusText = statusText
        self.pendingCount = pendingCount
        self.roomID = roomID
        self.itemID = itemID
    }
}

public enum MessageDeliveryState: String, Codable, Sendable {
    case queued
    case sending
    case accepted
    case echoed
    case permanentFailure

    public var label: String {
        switch self {
        case .queued: "Queued"
        case .sending: "Sending"
        case .accepted: "Sent"
        case .echoed: "Read"
        case .permanentFailure: "Rejected"
        }
    }

    public static func reconciled(
        mappedState: MessageDeliveryState?,
        isOwnMessage: Bool,
        eventID: String?,
        hasReadReceipts: Bool
    ) -> MessageDeliveryState? {
        if hasReadReceipts {
            return .echoed
        }

        switch mappedState {
        case .accepted, .echoed, .sending:
            return mappedState
        case .permanentFailure:
            if isOwnMessage, let eventID, eventID.hasPrefix("$") {
                return .accepted
            }
            return .permanentFailure
        case .queued, .none:
            break
        }

        guard isOwnMessage, let eventID, eventID.hasPrefix("$") else {
            return mappedState
        }
        return .accepted
    }
}

public struct ReadReceipt: Hashable, Codable, Sendable {
    public let userID: String
    public let displayName: String
    public let avatarURL: String?
    public let readAt: Date?

    public init(userID: String, displayName: String, avatarURL: String? = nil, readAt: Date?) {
        self.userID = userID
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.readAt = readAt
    }
}

public struct ReceiptSummary: Hashable, Codable, Sendable {
    public let sentAt: Date?
    public let deliveredAt: Date?
    public let readReceipts: [ReadReceipt]

    public init(sentAt: Date?, deliveredAt: Date?, readReceipts: [ReadReceipt]) {
        self.sentAt = sentAt
        self.deliveredAt = deliveredAt
        self.readReceipts = readReceipts
    }
}

public enum TimelineItemKind: String, Codable, Sendable {
    case message
    case statusSummary
}

public enum TimelineMediaKind: String, Codable, Sendable {
    case image
    case video
    case audio
    case file
}

public enum TimelineStatusAction: String, Codable, Sendable {
    case joined
    case left
    case banned
    case unbanned
    case kicked
    case kickedAndBanned
    case invited
    case acceptedInvite
    case rejectedInvite
    case revokedInvite
    case requestedJoin
    case allowedIn
    case cancelledJoinRequest
    case denied
    case generic

    public var verbPhrase: String {
        switch self {
        case .joined:
            return "joined"
        case .left:
            return "left"
        case .banned:
            return "was banned"
        case .unbanned:
            return "was unbanned"
        case .kicked:
            return "was kicked"
        case .kickedAndBanned:
            return "was removed and banned"
        case .invited:
            return "was invited"
        case .acceptedInvite:
            return "accepted the invite"
        case .rejectedInvite:
            return "rejected the invite"
        case .revokedInvite:
            return "had the invite revoked"
        case .requestedJoin:
            return "requested to join"
        case .allowedIn:
            return "was allowed in"
        case .cancelledJoinRequest:
            return "cancelled the join request"
        case .denied:
            return "was denied"
        case .generic:
            return "updated status"
        }
    }
}

public struct TimelineMediaAttachment: Hashable, Codable, Sendable {
    public let kind: TimelineMediaKind
    public let body: String
    public let filename: String?
    public let sourceURL: String
    public let sourceJSON: String
    public let mimeType: String?
    public let thumbnailSourceURL: String?
    public let thumbnailSourceJSON: String?
    public let thumbnailMimeType: String?
    public let width: Int?
    public let height: Int?
    public let durationSeconds: Double?
    public let allowsDirectDownload: Bool

    public init(
        kind: TimelineMediaKind,
        body: String,
        filename: String?,
        sourceURL: String,
        sourceJSON: String,
        mimeType: String?,
        thumbnailSourceURL: String? = nil,
        thumbnailSourceJSON: String? = nil,
        thumbnailMimeType: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        durationSeconds: Double? = nil,
        allowsDirectDownload: Bool = false
    ) {
        self.kind = kind
        self.body = body
        self.filename = filename
        self.sourceURL = sourceURL
        self.sourceJSON = sourceJSON
        self.mimeType = mimeType
        self.thumbnailSourceURL = thumbnailSourceURL
        self.thumbnailSourceJSON = thumbnailSourceJSON
        self.thumbnailMimeType = thumbnailMimeType
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.allowsDirectDownload = allowsDirectDownload
    }
}

public struct TimelineStatusDetails: Hashable, Codable, Sendable {
    public let actorID: String
    public let actorDisplayName: String
    public let action: TimelineStatusAction
    public let renderedText: String

    public init(actorID: String, actorDisplayName: String, action: TimelineStatusAction, renderedText: String) {
        self.actorID = actorID
        self.actorDisplayName = actorDisplayName
        self.action = action
        self.renderedText = renderedText
    }
}

public struct TimelineMediaLoadState: Hashable, Codable, Sendable {
    public let thumbnailFileURL: URL?
    public let originalFileURL: URL?
    public let isLoadingThumbnail: Bool
    public let isLoadingOriginal: Bool
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let errorDescription: String?

    public init(
        thumbnailFileURL: URL? = nil,
        originalFileURL: URL? = nil,
        isLoadingThumbnail: Bool = false,
        isLoadingOriginal: Bool = false,
        receivedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        errorDescription: String? = nil
    ) {
        self.thumbnailFileURL = thumbnailFileURL
        self.originalFileURL = originalFileURL
        self.isLoadingThumbnail = isLoadingThumbnail
        self.isLoadingOriginal = isLoadingOriginal
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.errorDescription = errorDescription
    }
}

public struct TimelineItem: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let roomID: RoomIdentifier
    public let senderID: String
    public let senderDisplayName: String
    public let body: String
    public let timestamp: Date
    public let kind: TimelineItemKind
    public let media: TimelineMediaAttachment?
    public let status: TimelineStatusDetails?
    public let isOwnMessage: Bool
    public let isEncrypted: Bool
    public let isEdited: Bool
    public let replyPreview: String?
    public let threadReplyCount: Int
    public let deliveryState: MessageDeliveryState?
    public let receipts: ReceiptSummary
    public let transactionID: EventTransactionIdentifier?
    public let isDeleted: Bool
    public let deletedAt: Date?

    public init(
        id: String,
        roomID: RoomIdentifier,
        senderID: String,
        senderDisplayName: String,
        body: String,
        timestamp: Date,
        kind: TimelineItemKind = .message,
        media: TimelineMediaAttachment? = nil,
        status: TimelineStatusDetails? = nil,
        isOwnMessage: Bool,
        isEncrypted: Bool,
        isEdited: Bool = false,
        replyPreview: String? = nil,
        threadReplyCount: Int = 0,
        deliveryState: MessageDeliveryState? = nil,
        receipts: ReceiptSummary = ReceiptSummary(sentAt: nil, deliveredAt: nil, readReceipts: []),
        transactionID: EventTransactionIdentifier? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.roomID = roomID
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.body = body
        self.timestamp = timestamp
        self.kind = kind
        self.media = media
        self.status = status
        self.isOwnMessage = isOwnMessage
        self.isEncrypted = isEncrypted
        self.isEdited = isEdited
        self.replyPreview = replyPreview
        self.threadReplyCount = threadReplyCount
        self.deliveryState = deliveryState
        self.receipts = receipts
        self.transactionID = transactionID
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }
}

public struct RoomDetails: Hashable, Codable, Sendable {
    public let roomID: RoomIdentifier
    public let displayName: String
    public let topic: String
    public let isEncrypted: Bool
    public let memberCount: Int
    public let pinnedMessages: [String]

    public init(
        roomID: RoomIdentifier,
        displayName: String,
        topic: String,
        isEncrypted: Bool,
        memberCount: Int,
        pinnedMessages: [String]
    ) {
        self.roomID = roomID
        self.displayName = displayName
        self.topic = topic
        self.isEncrypted = isEncrypted
        self.memberCount = memberCount
        self.pinnedMessages = pinnedMessages
    }
}

public enum VerificationStatus: String, Codable, Sendable {
    case unknown
    case unverified
    case verified

    public var label: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .unverified:
            return "Unverified"
        case .verified:
            return "Verified"
        }
    }
}

public enum VerificationFlowState: String, Codable, Sendable {
    case idle
    case requested
    case readyForSas
    case showingChallenge
    case cancelled
    case failed
}

public struct VerificationEmoji: Hashable, Codable, Sendable, Identifiable {
    public let symbol: String
    public let description: String

    public var id: String { "\(symbol)-\(description)" }

    public init(symbol: String, description: String) {
        self.symbol = symbol
        self.description = description
    }
}

public struct VerificationSnapshot: Hashable, Codable, Sendable {
    public var state: VerificationStatus
    public var flow: VerificationFlowState
    public var deviceID: String?
    public var emojis: [VerificationEmoji]
    public var decimals: [UInt16]
    public var message: String?

    public init(
        state: VerificationStatus,
        flow: VerificationFlowState = .idle,
        deviceID: String?,
        emojis: [VerificationEmoji] = [],
        decimals: [UInt16] = [],
        message: String? = nil
    ) {
        self.state = state
        self.flow = flow
        self.deviceID = deviceID
        self.emojis = emojis
        self.decimals = decimals
        self.message = message
    }

    public static let initial = VerificationSnapshot(state: .unknown, flow: .idle, deviceID: nil)

    public var statusText: String {
        switch (state, flow) {
        case (.verified, _):
            return "Verified"
        case (_, .requested):
            return "Verification requested"
        case (_, .readyForSas):
            return "Ready for SAS"
        case (_, .showingChallenge):
            return "Compare SAS"
        case (_, .cancelled):
            return "Verification cancelled"
        case (_, .failed):
            return "Verification failed"
        case (.unverified, .idle):
            return "Unverified"
        case (.unknown, .idle):
            return "Unknown"
        }
    }

    public var canRequest: Bool {
        state != .verified && [.idle, .cancelled, .failed].contains(flow)
    }

    public var canStartSas: Bool {
        state != .verified && [.requested, .readyForSas].contains(flow)
    }

    public var canApprove: Bool {
        flow == .showingChallenge && (!emojis.isEmpty || !decimals.isEmpty)
    }

    public var canDecline: Bool {
        state != .verified && [.requested, .readyForSas, .showingChallenge].contains(flow)
    }

    public var canCancel: Bool {
        state != .verified && [.requested, .readyForSas, .showingChallenge].contains(flow)
    }
}

public struct SendQueueSnapshot: Hashable, Codable, Sendable {
    public let transactionID: String
    public let roomID: String
    public let state: MessageDeliveryState
    public let attemptCount: Int
    public let eventID: String?
    public let errorDescription: String?

    public init(
        transactionID: String,
        roomID: String,
        state: MessageDeliveryState,
        attemptCount: Int,
        eventID: String?,
        errorDescription: String?
    ) {
        self.transactionID = transactionID
        self.roomID = roomID
        self.state = state
        self.attemptCount = attemptCount
        self.eventID = eventID
        self.errorDescription = errorDescription
    }
}

public enum ClientSessionState: Equatable, Sendable {
    case launching
    case restoring(message: String)
    case signingIn(message: String)
    case signedOut(message: String?)
    case connected

    public var statusMessage: String? {
        switch self {
        case .launching:
            return "Launching…"
        case let .restoring(message), let .signingIn(message):
            return message
        case let .signedOut(message):
            return message
        case .connected:
            return nil
        }
    }

    public var isBusy: Bool {
        switch self {
        case .launching, .restoring, .signingIn:
            return true
        case .signedOut, .connected:
            return false
        }
    }
}
