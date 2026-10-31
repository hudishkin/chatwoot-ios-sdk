import Combine

extension Publisher where Failure == Never {
    func eagerValues() -> AsyncStream<Output> {
        AsyncStream { continuation in
            let cancellable = sink(
                receiveCompletion: { _ in continuation.finish() },
                receiveValue: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
