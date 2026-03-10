import Foundation

public final class AsyncBroadcaster<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var latestValue: Value?

    public init(initialValue: Value? = nil) {
        latestValue = initialValue
    }

    public func stream() -> AsyncStream<Value> {
        let streamID = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[streamID] = continuation
            let latestValue = latestValue
            lock.unlock()

            if let latestValue {
                continuation.yield(latestValue)
            }

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: streamID)
            }
        }
    }

    public func yield(_ value: Value) {
        lock.lock()
        latestValue = value
        let activeContinuations = Array(continuations.values)
        lock.unlock()

        for continuation in activeContinuations {
            continuation.yield(value)
        }
    }

    private func removeContinuation(id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
