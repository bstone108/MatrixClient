import Diagnostics
import Foundation
import Persistence

public enum SendTransportFailure: Error, Sendable {
    case transient(String)
    case permanent(String)
}

public enum SendReconciliationResult: Sendable {
    case missing
    case alreadyAccepted(eventID: String?)
}

public enum SendAttemptResult: Sendable {
    case accepted(eventID: String?)
}

public struct QueuedMessage: Identifiable, Hashable, Codable, Sendable {
    public var id: Int64? { persistentID }
    public let persistentID: Int64?
    public let accountID: AccountIdentifier
    public let roomID: RoomIdentifier
    public let transactionID: EventTransactionIdentifier
    public let senderID: String
    public let body: String
    public let createdAt: Date
    public let updatedAt: Date
    public let state: MessageDeliveryState
    public let eventID: String?
    public let attemptCount: Int
    public let errorDescription: String?
}

public protocol SendQueueTransport: Sendable {
    func reconcile(message: QueuedMessage) async throws -> SendReconciliationResult
    func send(message: QueuedMessage) async throws -> SendAttemptResult
}

public actor ReliableSendQueue {
    private enum Constants {
        static let transientRetryDelay: Duration = .milliseconds(250)
    }

    private let repository: QueuedMessageRepository
    private let diagnostics: DiagnosticsService
    private let transport: any SendQueueTransport
    private let broadcaster = AsyncBroadcaster<[QueuedMessage]>(initialValue: [])
    private var updateHandlers: [UUID: @Sendable (QueuedMessage) async -> Void] = [:]
    private var processingTask: Task<Void, Never>?

    public init(
        repository: QueuedMessageRepository,
        diagnostics: DiagnosticsService,
        transport: any SendQueueTransport
    ) {
        self.repository = repository
        self.diagnostics = diagnostics
        self.transport = transport
    }

    public func stream() -> AsyncStream<[QueuedMessage]> {
        broadcaster.stream()
    }

    public func snapshot() async -> [QueuedMessage] {
        let records = (try? await repository.fetchAll()) ?? []
        return records.map(Self.mapRecord)
    }

    public func addUpdateHandler(_ handler: @escaping @Sendable (QueuedMessage) async -> Void) {
        updateHandlers[UUID()] = handler
    }

    public func resumePendingDelivery() async {
        await publishSnapshot()
        scheduleProcessingIfNeeded()
    }

    public func enqueue(
        accountID: AccountIdentifier,
        roomID: RoomIdentifier,
        senderID: String,
        body: String,
        transactionID: EventTransactionIdentifier
    ) async {
        let record = QueuedMessageRecord(
            accountID: accountID.rawValue,
            roomID: roomID.rawValue,
            transactionID: transactionID.rawValue,
            senderID: senderID,
            body: body,
            state: MessageDeliveryState.queued.rawValue
        )
        do {
            let saved = try await repository.save(record)
            let mapped = Self.mapRecord(saved)
            await notifyUpdate(mapped)
            await diagnostics.record(.notice, category: "SendQueue", message: "Enqueued local echo", metadata: [
                "roomID": roomID.rawValue,
                "transactionID": transactionID.rawValue
            ])
            await publishSnapshot()
            scheduleProcessingIfNeeded()
        } catch {
            await diagnostics.record(.error, category: "SendQueue", message: "Failed to persist queued message", metadata: [
                "roomID": roomID.rawValue,
                "transactionID": transactionID.rawValue,
                "error": error.localizedDescription
            ])
        }
    }

    private func scheduleProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task {
            await processLoop()
        }
    }

    private func processLoop() async {
        defer { processingTask = nil }
        while !Task.isCancelled {
            let pending = (try? await repository.fetchPending()) ?? []
            guard let nextRecord = pending.first else {
                await publishSnapshot()
                return
            }
            let message = Self.mapRecord(nextRecord)
            await process(message)
        }
    }

    private func process(_ message: QueuedMessage) async {
        do {
            let reconciliation = try await transport.reconcile(message: message)
            switch reconciliation {
            case .alreadyAccepted(let eventID):
                if let updated = try await repository.updateState(
                    transactionID: message.transactionID.rawValue,
                    state: MessageDeliveryState.echoed.rawValue,
                    eventID: eventID
                ) {
                    let mapped = Self.mapRecord(updated)
                    await notifyUpdate(mapped)
                    await publishSnapshot()
                }
                return
            case .missing:
                break
            }

            let sendingRecord = try await repository.updateState(
                transactionID: message.transactionID.rawValue,
                state: MessageDeliveryState.sending.rawValue,
                attemptCount: message.attemptCount + 1,
                errorDescription: nil
            )
            if let sendingRecord {
                await notifyUpdate(Self.mapRecord(sendingRecord))
                await publishSnapshot()
            }

            let result = try await transport.send(message: message)
            switch result {
            case .accepted(let eventID):
                if let accepted = try await repository.updateState(
                    transactionID: message.transactionID.rawValue,
                    state: MessageDeliveryState.accepted.rawValue,
                    eventID: eventID
                ) {
                    let mapped = Self.mapRecord(accepted)
                    await notifyUpdate(mapped)
                    await publishSnapshot()
                }
            }
        } catch let failure as SendTransportFailure {
            switch failure {
            case .transient(let description):
                if let updated = try? await repository.updateState(
                    transactionID: message.transactionID.rawValue,
                    state: MessageDeliveryState.queued.rawValue,
                    attemptCount: message.attemptCount + 1,
                    errorDescription: description
                ) {
                    await diagnostics.record(.notice, category: "SendQueue", message: "Transient send failure; message kept queued", metadata: [
                        "transactionID": message.transactionID.rawValue,
                        "error": description
                    ])
                    await notifyUpdate(Self.mapRecord(updated))
                }
                await publishSnapshot()
                try? await Task.sleep(for: Constants.transientRetryDelay)
            case .permanent(let description):
                if let failed = try? await repository.updateState(
                    transactionID: message.transactionID.rawValue,
                    state: MessageDeliveryState.permanentFailure.rawValue,
                    attemptCount: message.attemptCount + 1,
                    errorDescription: description
                ) {
                    await diagnostics.record(.error, category: "SendQueue", message: "Permanent send failure", metadata: [
                        "transactionID": message.transactionID.rawValue,
                        "error": description
                    ])
                    await notifyUpdate(Self.mapRecord(failed))
                    await publishSnapshot()
                }
            }
        } catch {
            if let updated = try? await repository.updateState(
                transactionID: message.transactionID.rawValue,
                state: MessageDeliveryState.queued.rawValue,
                attemptCount: message.attemptCount + 1,
                errorDescription: error.localizedDescription
            ) {
                await diagnostics.record(.notice, category: "SendQueue", message: "Unexpected send error; queue retained", metadata: [
                    "transactionID": message.transactionID.rawValue,
                    "error": error.localizedDescription
                ])
                await notifyUpdate(Self.mapRecord(updated))
                await publishSnapshot()
                try? await Task.sleep(for: Constants.transientRetryDelay)
            }
        }
    }

    private func publishSnapshot() async {
        let records = (try? await repository.fetchAll()) ?? []
        let snapshot = records.map(Self.mapRecord)
        broadcaster.yield(snapshot)
    }

    private func notifyUpdate(_ message: QueuedMessage) async {
        for handler in updateHandlers.values {
            await handler(message)
        }
    }

    private static func mapRecord(_ record: QueuedMessageRecord) -> QueuedMessage {
        QueuedMessage(
            persistentID: record.id,
            accountID: AccountIdentifier(rawValue: record.accountID),
            roomID: RoomIdentifier(rawValue: record.roomID),
            transactionID: EventTransactionIdentifier(rawValue: record.transactionID),
            senderID: record.senderID,
            body: record.body,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            state: MessageDeliveryState(rawValue: record.state) ?? .queued,
            eventID: record.eventID,
            attemptCount: record.attemptCount,
            errorDescription: record.errorDescription
        )
    }
}
