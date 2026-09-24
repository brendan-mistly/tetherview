import Foundation
import Network

/// ByteStream over a TCP connection (Network.framework), pinned to Wi-Fi so
/// traffic to the camera never tries the cellular interface.
final class NWStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Resumes a continuation at most once (callbacks, timeouts and
    /// cancellation can all race to finish the same operation).
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        init(_ c: CheckedContinuation<T, Error>) { continuation = c }
        /// Returns true if this call is the one that finished the operation.
        @discardableResult
        func resume(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(with: result)
            return c != nil
        }
    }

    static func connect(host: String, port: UInt16, timeout: TimeInterval) async throws -> NWStream {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        let params = NWParameters(tls: nil, tcp: tcp)
        params.requiredInterfaceType = .wifi
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: port)!,
                                      using: params)
        let queue = DispatchQueue(label: "tetherview.tcp.\(port)")
        let stream = NWStream(connection: connection, queue: queue)

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = Once(c)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(.success(()))
                case .failed(let error):
                    once.resume(.failure(error))
                case .waiting(let error):
                    // No route yet (not on the camera's Wi-Fi, or the Local
                    // Network prompt is showing). Give up rather than hang.
                    once.resume(.failure(error))
                    connection.cancel()
                case .cancelled:
                    once.resume(.failure(PTPError("connection cancelled")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.resume(.failure(PTPError("connection timed out"))) {
                    connection.cancel()
                }
            }
        }
        return stream
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func receive(exactly count: Int, timeout: TimeInterval) async throws -> Data {
        guard count > 0 else { return Data() }
        var out = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while out.count < count {
            let remaining = max(0.1, deadline.timeIntervalSinceNow)
            let chunk = try await receiveSome(max: count - out.count, timeout: remaining)
            out.append(chunk)
        }
        return out
    }

    private func receiveSome(max: Int, timeout: TimeInterval) async throws -> Data {
        let connection = self.connection
        let box = OnceBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                let once = Once(c)
                box.set(once)
                connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, isComplete, error in
                    if let error = error {
                        once.resume(.failure(error))
                    } else if let data = data, !data.isEmpty {
                        once.resume(.success(data))
                    } else if isComplete {
                        once.resume(.failure(PTPError("camera closed the connection")))
                    } else {
                        once.resume(.success(Data()))
                    }
                }
                queue.asyncAfter(deadline: .now() + timeout) {
                    // A stalled read means the camera stopped talking; the
                    // connection can't be reused after abandoning a read.
                    if once.resume(.failure(PTPError("camera stopped responding"))) {
                        connection.cancel()
                    }
                }
            }
        } onCancel: {
            box.resume(.failure(CancellationError()))
            connection.cancel()
        }
    }

    /// Holds the current read's Once so cancellation can finish it.
    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var once: Once<Data>?
        private var cancelledEarly = false
        func set(_ o: Once<Data>) {
            lock.lock()
            if cancelledEarly {
                lock.unlock()
                o.resume(.failure(CancellationError()))
                return
            }
            once = o
            lock.unlock()
        }
        func resume(_ r: Result<Data, Error>) {
            lock.lock()
            let o = once
            if o == nil { cancelledEarly = true }
            lock.unlock()
            o?.resume(r)
        }
    }

    func close() {
        connection.cancel()
    }
}
