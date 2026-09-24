import Foundation

/// A reliable, ordered byte stream (a TCP connection). The iPhone app backs
/// this with Network.framework; tests back it with an in-memory pipe.
public protocol ByteStream: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// Reads exactly `count` bytes, or throws.
    func receive(exactly count: Int, timeout: TimeInterval) async throws -> Data
    func close()
}

/// Opens a TCP connection to the camera on the given port.
public typealias StreamOpener = @Sendable (_ port: UInt16) async throws -> ByteStream

/// In-memory, thread-safe pipe used by tests and by the simulated camera.
public final class MemoryPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var closed = false
    private var waiters: [(Int, CheckedContinuation<Data, Error>, UUID)] = []

    public init() {}

    public func write(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let ready = drainLocked()
        lock.unlock()
        for (c, d) in ready { c.resume(returning: d) }
    }

    public func close() {
        lock.lock()
        closed = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for (_, c, _) in pending { c.resume(throwing: PTPError("stream closed")) }
    }

    public func read(exactly count: Int, timeout: TimeInterval = 3600) async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
                lock.lock()
                if closed && buffer.count < count {
                    lock.unlock()
                    c.resume(throwing: PTPError("stream closed"))
                    return
                }
                waiters.append((count, c, id))
                let ready = drainLocked()
                lock.unlock()
                for (cc, d) in ready { cc.resume(returning: d) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.fail(id, PTPError("timed out"))
                }
            }
        } onCancel: {
            self.fail(id, CancellationError())
        }
    }

    private func fail(_ id: UUID, _ error: Error) {
        lock.lock()
        guard let i = waiters.firstIndex(where: { $0.2 == id }) else { lock.unlock(); return }
        let w = waiters.remove(at: i)
        lock.unlock()
        w.1.resume(throwing: error)
    }

    private func drainLocked() -> [(CheckedContinuation<Data, Error>, Data)] {
        var out: [(CheckedContinuation<Data, Error>, Data)] = []
        while let first = waiters.first, buffer.count >= first.0 {
            waiters.removeFirst()
            let chunk = Data(buffer.prefix(first.0))
            buffer.removeFirst(first.0)
            out.append((first.1, chunk))
        }
        return out
    }
}

/// One end of an in-memory duplex connection.
public final class MemoryStream: ByteStream, @unchecked Sendable {
    private let inbound: MemoryPipe
    private let outbound: MemoryPipe

    public init(inbound: MemoryPipe, outbound: MemoryPipe) {
        self.inbound = inbound
        self.outbound = outbound
    }

    /// Returns the two ends of a connected pair.
    public static func pair() -> (MemoryStream, MemoryStream) {
        let a = MemoryPipe(), b = MemoryPipe()
        return (MemoryStream(inbound: a, outbound: b), MemoryStream(inbound: b, outbound: a))
    }

    public func send(_ data: Data) async throws { outbound.write(data) }

    public func receive(exactly count: Int, timeout: TimeInterval) async throws -> Data {
        try await inbound.read(exactly: count, timeout: timeout)
    }

    public func close() {
        inbound.close()
        outbound.close()
    }
}
