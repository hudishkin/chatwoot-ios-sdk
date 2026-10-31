import Foundation

protocol WebSocketTransport: AnyObject, Sendable {
    func connect() -> AsyncStream<SocketFrame>

    @discardableResult
    func send(_ text: String) -> Bool

    func close(code: Int, reason: String)

    func cancel()
}

final class URLSessionWebSocketTransport: NSObject, WebSocketTransport, @unchecked Sendable {
    private struct Connection {
        let generation: UInt64
        let task: URLSessionWebSocketTask
        let continuation: AsyncStream<SocketFrame>.Continuation
    }

    private let request: URLRequest
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var connection: Connection?

    init(request: URLRequest) {
        self.request = request
        super.init()
    }

    convenience init(baseURL: URL) {
        self.init(request: WebSocketRequest.build(baseURL: baseURL))
    }

    func connect() -> AsyncStream<SocketFrame> {
        AsyncStream { continuation in
            lock.lock()
            generation += 1
            let myGeneration = generation
            let task = session.webSocketTask(with: request)
            connection = Connection(generation: myGeneration, task: task, continuation: continuation)
            lock.unlock()

            CWLog.i(.ws, "connect gen=\(myGeneration) host=\(request.url?.host ?? "-")")

            continuation.onTermination = { [weak self, weak task] _ in
                task?.cancel()
                self?.dropConnection(myGeneration)
            }

            task.resume()
            if emit(myGeneration, .opened) {
                scheduleReceive(task: task, generation: myGeneration)
            }
        }
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        lock.lock()
        let task = connection?.task
        lock.unlock()
        guard let task, task.state == .running else { return false }
        task.send(.string(text)) { error in
            if error != nil { CWLog.d(.ws, "send completion failed") }
        }
        return true
    }

    func close(code: Int, reason: String) {
        lock.lock()
        let task = connection?.task
        lock.unlock()
        guard let task else { return }
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason.data(using: .utf8))
    }

    func cancel() {
        lock.lock()
        let task = connection?.task
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Private

    @discardableResult
    private func emit(_ generation: UInt64, _ frame: SocketFrame) -> Bool {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection, connection.generation == generation else { return false }
        connection.continuation.yield(frame)
        return true
    }

    private func scheduleReceive(task: URLSessionWebSocketTask, generation: UInt64) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            let alive = self.connection?.generation == generation
            self.lock.unlock()
            guard alive else { return }
            switch result {
            case .success(.string(let text)):
                if self.emit(generation, .text(text)) {
                    self.scheduleReceive(task: task, generation: generation)
                }
            case .success:
                self.scheduleReceive(task: task, generation: generation)
            case .failure(let error):
                self.finish(generation, frame: .failed(error))
            }
        }
    }

    private func finish(_ generation: UInt64, frame: SocketFrame) {
        lock.lock()
        guard connection?.generation == generation, let current = connection else {
            lock.unlock()
            return
        }
        connection = nil
        lock.unlock()
        current.continuation.yield(frame)
        current.continuation.finish()
    }

    private func dropConnection(_ generation: UInt64) {
        lock.lock()
        if connection?.generation == generation {
            connection = nil
        }
        lock.unlock()
    }
}

extension URLSessionWebSocketTransport: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        lock.lock()
        guard connection?.task === webSocketTask, let generation = connection?.generation else {
            lock.unlock()
            return
        }
        lock.unlock()
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        CWLog.i(.ws, "closed gen=\(generation) code=\(closeCode.rawValue)")
        finish(generation, frame: .closed(code: closeCode.rawValue, reason: reasonText))
    }
}
