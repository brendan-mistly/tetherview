// Fujifilm Wi-Fi remote (live view) over PTP/IP.
//
// Protocol as implemented by libfuji (github.com/petabyt/libfuji, MIT) for
// the XApp-era "Bluetooth handover" connection, confirmed on an X-T5:
//   * Camera at 192.168.0.1. TCP 55740 = commands, 55741 = events,
//     55742 = live view.
//   * A Fujifilm-specific init packet, then USB-style PTP containers over TCP
//     (u32 length, u16 type, u16 code, u32 transaction, params).
//   * OpenSession uses transaction ID 1.
//   * Poll 0xD212 (event list) until 0xDF00 (camera state) is non-zero.
//   * 0xDF01 (client state) = 20 selects the XApp remote mode; = 22 plus
//     InitiateOpenCapture starts live view, which then streams on 55742 as
//     [u32 total length][14 header bytes][JPEG].

import Foundation

public enum FujiIP {
    public static let host = "192.168.0.1"
    public static let commandPort: UInt16 = 55740
    public static let eventPort: UInt16 = 55741
    public static let liveViewPort: UInt16 = 55742
    public static let protocolVersion: UInt32 = 0x8F53E4F2
    public static let initRequest: UInt32 = 1
    public static let initAck: UInt32 = 2
    public static let initFail: UInt32 = 5
    public static let goodbye = Data([0x08, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])

    // Properties
    public static let eventsList: UInt32 = 0xD212
    public static let compressSmall: UInt32 = 0xD226
    public static let correctFileSize: UInt32 = 0xD227
    public static let unknownD22B: UInt32 = 0xD22B
    public static let storageID: UInt32 = 0xD244
    public static let importObjectCount: UInt32 = 0xD620
    public static let importObjectHandles: UInt32 = 0xD621
    public static let cameraState: UInt32 = 0xDF00
    public static let clientState: UInt32 = 0xDF01
    public static let imageGetVersion: UInt32 = 0xDF21
    public static let getObjectVersion: UInt32 = 0xDF22
    public static let remoteVersion: UInt32 = 0xDF24
    public static let remoteGetObjectVersion: UInt32 = 0xDF25
    public static let remotePhotoViewExVersion: UInt32 = 0xDF28
    public static let unknownDF2A: UInt32 = 0xDF2A

    // Operations
    public static let openSession: UInt16 = 0x1002
    public static let getExtensionObjectInfo: UInt16 = 0x9054
    public static let getExtensionThumb: UInt16 = 0x9055
    public static let getImageImportFolders: UInt16 = 0x9050
    public static let getImageImportDates: UInt16 = 0x9053

    // Values
    public static let cameraStateWaiting: UInt16 = 0
    public static let cameraStateRemote: UInt16 = 6
    public static let clientXAppGallery: UInt16 = 20
    public static let clientXAppLiveView: UInt16 = 22
}

// MARK: - Transport

/// PTP over the camera's command socket, using Fujifilm's framing.
public actor FujiIPTransport: PTPTransport {
    private let stream: ByteStream
    private let log: @Sendable (String) -> Void
    private var transactionID: UInt32 = 1
    public private(set) var lastTransactionID: UInt32 = 0
    // Actors are re-entrant across awaits; this keeps one transaction on the
    // wire at a time so replies can't be mixed up.
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func release() {
        if queue.isEmpty { busy = false } else { queue.removeFirst().resume() }
    }

    public init(stream: ByteStream, log: @escaping @Sendable (String) -> Void) {
        self.stream = stream
        self.log = log
    }

    /// Fujifilm init handshake. Returns the camera's name.
    public func handshake(clientName: String, timeout: TimeInterval = 20) async throws -> String {
        var p = Data()
        p.appendLE(UInt32(0x52))
        p.appendLE(FujiIP.initRequest)
        p.appendLE(FujiIP.protocolVersion)
        p.appendLE(UInt32(0x5D48A5AD))
        p.appendLE(UInt32(0x0B7FB287))
        p.appendLE(UInt32(0xD0DED5D3))
        p.appendLE(UInt32(0))
        var name = Data()
        for u in clientName.utf16.prefix(26) { name.appendLE(u) }
        name.append(Data(count: 54 - name.count))       // NUL-padded, 54 bytes
        p.append(name)
        try await stream.send(p)

        let lenData = try await stream.receive(exactly: 4, timeout: timeout)
        let len = Int(lenData.readLE32(at: 0) ?? 0)
        guard len >= 8, len < 4096 else { throw PTPError("Bad init reply length \(len)") }
        let rest = try await stream.receive(exactly: len - 4, timeout: timeout)
        let reply = lenData + rest
        let type = reply.readLE32(at: 4) ?? 0
        if type == FujiIP.initFail {
            let reason = reply.readLE32(at: 8) ?? 0
            throw FujiWiFiFailure.refused(String(format: "The camera refused the connection (code 0x%08X). Make sure no other app (like Fujifilm XApp) is connected to it, then try again.", reason))
        }
        guard type == FujiIP.initAck else { throw PTPError("Unexpected init reply type \(type)") }
        return Self.utf16String(reply, from: 28)
    }

    /// The next command uses this transaction ID (OpenSession must use 1).
    public func setNextTransactionID(_ id: UInt32) { transactionID = id }

    public func send(_ opcode: UInt16, params: [UInt32], outData: Data?, timeout: TimeInterval) async throws -> PTPResult {
        await acquire()
        defer { release() }
        let tx = transactionID
        transactionID &+= 1
        lastTransactionID = tx

        var packet = PTPContainer.command(opcode: opcode, transactionID: tx, params: params)
        if let out = outData {
            packet.appendLE(UInt32(PTPContainer.headerSize + out.count))
            packet.appendLE(PTPContainer.typeData)
            packet.appendLE(opcode)
            packet.appendLE(tx)
            packet.append(out)
        }
        try await stream.send(packet)

        var data = Data()
        while true {
            let (type, code, payload, params) = try await readContainer(timeout: timeout)
            switch type {
            case PTPContainer.typeData:
                data.append(payload)
            case PTPContainer.typeResponse:
                return PTPResult(code: code, params: params, data: data)
            default:
                log("Ignoring container type \(type) code 0x\(String(code, radix: 16))")
            }
        }
    }

    public func sendGoodbye() async {
        await acquire()
        defer { release() }
        try? await stream.send(FujiIP.goodbye)
    }

    private func readContainer(timeout: TimeInterval) async throws -> (UInt16, UInt16, Data, [UInt32]) {
        let head = try await stream.receive(exactly: PTPContainer.headerSize, timeout: timeout)
        let length = Int(head.readLE32(at: 0) ?? 0)
        guard length >= PTPContainer.headerSize, length < 256 * 1024 * 1024 else {
            throw PTPError("Bad container length \(length)")
        }
        let type = head.readLE16(at: 4) ?? 0
        let code = head.readLE16(at: 6) ?? 0
        let body = length > PTPContainer.headerSize
            ? try await stream.receive(exactly: length - PTPContainer.headerSize, timeout: timeout)
            : Data()
        var params: [UInt32] = []
        if type == PTPContainer.typeResponse {
            var off = 0
            while off + 4 <= body.count, params.count < 5 {
                params.append(body.readLE32(at: off) ?? 0)
                off += 4
            }
        }
        return (type, code, body, params)
    }

    static func utf16String(_ d: Data, from offset: Int) -> String {
        var units: [UInt16] = []
        var off = offset
        while let u = d.readLE16(at: off), u != 0 {
            units.append(u)
            off += 2
        }
        return String(decoding: units, as: UTF16.self)
    }
}

// MARK: - Session

public struct FujiEvent: Sendable, Equatable {
    public var code: UInt16
    public var value: UInt32
}

public enum FujiWiFiFailure: Error, CustomStringConvertible, Sendable {
    case cannotReachCamera(String)
    case refused(String)
    case timedOutWaitingForApproval
    case step(String, UInt16)

    public var description: String {
        switch self {
        case .cannotReachCamera(let why):
            return "Can't reach the camera at 192.168.0.1 (\(why)). Is the iPhone joined to the camera's Wi-Fi?"
        case .refused(let why): return why
        case .timedOutWaitingForApproval:
            return "The camera never allowed the connection. Check the camera's screen for an OK prompt."
        case .step(let what, let code):
            return "\(what) failed (\(PTPResponse.name(code)))."
        }
    }
}

/// Runs the Fujifilm Wi-Fi setup and live view, reporting frames as JPEG data.
public final class FujiWiFiLiveView: @unchecked Sendable {
    public typealias Log = @Sendable (String) -> Void

    private let open: StreamOpener
    private let log: Log
    private let clientName: String

    public init(clientName: String = "Tetherview", open: @escaping StreamOpener, log: @escaping Log) {
        self.clientName = clientName
        self.open = open
        self.log = log
    }

    public func run(onStatus: @escaping @Sendable (String) -> Void,
                    onFrame: @escaping @Sendable (Data) -> Void,
                    onStats: @escaping @Sendable (Double) -> Void) async throws {
        let commandStream: ByteStream
        do {
            commandStream = try await open(FujiIP.commandPort)
        } catch {
            throw FujiWiFiFailure.cannotReachCamera("\(error)")
        }
        // Only report status once the camera is actually reachable.
        onStatus("Found the camera on Wi-Fi, connecting…")
        let t = FujiIPTransport(stream: commandStream, log: log)

        var streams: [ByteStream] = [commandStream]
        var liveViewTx: UInt32?
        defer { for s in streams { s.close() } }

        do {
            // 1. Handshake (the camera sometimes needs a second try).
            var cameraName = ""
            var lastError: Error?
            for attempt in 1...3 {
                do {
                    cameraName = try await t.handshake(clientName: clientName)
                    lastError = nil
                    break
                } catch let refusal as FujiWiFiFailure {
                    throw refusal
                } catch {
                    lastError = error
                    log("Handshake attempt \(attempt) failed: \(error)")
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            if let e = lastError { throw FujiWiFiFailure.refused("\(e)") }
            log("Connected to \(cameraName.isEmpty ? "camera" : cameraName)")
            try await Task.sleep(nanoseconds: 60_000_000) // camera needs >50 ms

            // 2. OpenSession, transaction 1.
            await t.setNextTransactionID(1)
            let session = try await t.send(FujiIP.openSession, params: [1], outData: nil, timeout: 15)
            log("OpenSession: \(PTPResponse.name(session.code))")
            guard session.isOK || session.code == 0x201E else { throw FujiWiFiFailure.step("OpenSession", session.code) }

            // 3. Wait for the camera to grant access.
            onStatus("Waiting for the camera… press OK on the camera if it asks")
            let deadline = Date().addingTimeInterval(90)
            var state: UInt32 = 0
            repeat {
                let events = try await getEvents(t)
                if let s = events.last(where: { $0.code == UInt16(FujiIP.cameraState) }) { state = s.value }
                if state != 0 { break }
                try await Task.sleep(nanoseconds: 150_000_000)
            } while Date() < deadline
            guard state != 0 else { throw FujiWiFiFailure.timedOutWaitingForApproval }
            log("Camera state: \(state)")

            // 4. Version properties (read for the log; the X-T5 flow reads them).
            for p in [FujiIP.getObjectVersion, FujiIP.remoteGetObjectVersion, FujiIP.imageGetVersion, FujiIP.remoteVersion] {
                let r = try await t.send(PTPOp.getDevicePropValue, params: [p], outData: nil, timeout: 10)
                log(String(format: "Prop 0x%04X = %@ (%@)", p, hex(r.data), PTPResponse.name(r.code)))
            }

            // 5. Client state: XApp remote mode. The camera may show a prompt.
            onStatus("Setting up remote mode… press OK on the camera if it asks")
            try await setU16(t, FujiIP.clientState, FujiIP.clientXAppGallery, timeout: 90, required: true)
            _ = try await getEvents(t)

            // 6. Gallery setup XApp performs before live view (tolerate refusals).
            try await echoProp(t, FujiIP.remotePhotoViewExVersion)
            try await setU16(t, FujiIP.compressSmall, 0, timeout: 10, required: false)
            try await setU16(t, FujiIP.correctFileSize, 0, timeout: 10, required: false)
            for (op, params) in [(FujiIP.getExtensionObjectInfo, [UInt32(0x10000001)]),
                                 (FujiIP.getExtensionThumb, [UInt32(0x10000001)]),
                                 (FujiIP.getImageImportFolders, [])] {
                let r = try await t.send(op, params: params, outData: nil, timeout: 15)
                log(String(format: "Op 0x%04X: %@", op, PTPResponse.name(r.code)))
            }
            _ = try await t.send(PTPOp.getDevicePropValue, params: [FujiIP.unknownD22B], outData: nil, timeout: 10)
            let dates = try await t.send(FujiIP.getImageImportDates, params: [0, 30000], outData: nil, timeout: 15)
            log("Op 0x9053: \(PTPResponse.name(dates.code))")
            _ = try await t.send(PTPOp.getDevicePropValue, params: [FujiIP.importObjectCount], outData: nil, timeout: 10)
            _ = try await t.send(PTPOp.getDevicePropValue, params: [FujiIP.importObjectHandles], outData: nil, timeout: 10)

            // 7. Enter live view.
            onStatus("Starting live view…")
            try await setU16(t, FujiIP.cameraState, FujiIP.cameraStateRemote, timeout: 15, required: true)
            try await setU16(t, FujiIP.clientState, FujiIP.clientXAppLiveView, timeout: 30, required: true)
            try await echoProp(t, FujiIP.unknownDF2A)

            let capture = try await t.send(PTPOp.initiateOpenCapture, params: [0, 0], outData: nil, timeout: 15)
            liveViewTx = await t.lastTransactionID
            log("InitiateOpenCapture: \(PTPResponse.name(capture.code))")
            guard capture.isOK else { throw FujiWiFiFailure.step("Starting live view", capture.code) }
            _ = try await getEvents(t)
            try await Task.sleep(nanoseconds: 60_000_000)

            let events = try await open(FujiIP.eventPort)
            streams.append(events)
            let video = try await open(FujiIP.liveViewPort)
            streams.append(video)
            log("Event and live-view sockets open")
            onStatus("Live")

            try await stream(t: t, video: video, events: events, onStatus: onStatus, onFrame: onFrame, onStats: onStats)
        } catch {
            await shutdown(t, liveViewTx: liveViewTx)
            throw error
        }
        await shutdown(t, liveViewTx: liveViewTx)
    }

    // MARK: - Live view loop

    private func stream(t: FujiIPTransport, video: ByteStream, events: ByteStream,
                        onStatus: @escaping @Sendable (String) -> Void,
                        onFrame: @escaping @Sendable (Data) -> Void,
                        onStats: @escaping @Sendable (Double) -> Void) async throws {
        let log = self.log
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Frames.
            group.addTask {
                var frames = 0
                var windowStart = Date()
                var loggedHeader = false
                while !Task.isCancelled {
                    let lenData = try await video.receive(exactly: 4, timeout: 20)
                    let total = Int(lenData.readLE32(at: 0) ?? 0)
                    guard total > 4, total < 32 * 1024 * 1024 else {
                        throw PTPError("Bad live-view frame length \(total)")
                    }
                    let body = try await video.receive(exactly: total - 4, timeout: 10)
                    if !loggedHeader {
                        loggedHeader = true
                        log("First frame: \(total) bytes, header \(hex(Data(body.prefix(14))))")
                    }
                    if let jpeg = JPEG.extract(from: body) {
                        onFrame(jpeg)
                        frames += 1
                    }
                    let elapsed = Date().timeIntervalSince(windowStart)
                    if elapsed >= 1 {
                        onStats(Double(frames) / elapsed)
                        frames = 0
                        windowStart = Date()
                    }
                }
            }
            // Drain the event socket so the camera never blocks on it.
            group.addTask {
                // Never ends the session on its own; it just stops draining if
                // the camera closes this socket.
                while !Task.isCancelled {
                    guard let lenData = try? await events.receive(exactly: 4, timeout: 3600) else {
                        try await Task.sleep(nanoseconds: 3_600_000_000_000)
                        continue
                    }
                    let n = Int(lenData.readLE32(at: 0) ?? 0)
                    if n > 4, n < 1_000_000 {
                        _ = try? await events.receive(exactly: n - 4, timeout: 10)
                    }
                }
            }
            // Keep-alive: poll the event list like XApp does.
            group.addTask { [self] in
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let ev = try await self.getEvents(t)
                    if let s = ev.first(where: { $0.code == UInt16(FujiIP.cameraState) }) {
                        log("Camera state changed to \(s.value)")
                    }
                }
            }
            // First task to finish (error or cancellation) ends the session.
            do {
                try await group.next()
            } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
        }
    }

    // MARK: - Helpers

    @discardableResult
    func getEvents(_ t: FujiIPTransport) async throws -> [FujiEvent] {
        let r = try await t.send(PTPOp.getDevicePropValue, params: [FujiIP.eventsList], outData: nil, timeout: 10)
        guard r.isOK else { return [] }
        return Self.parseEvents(r.data)
    }

    public static func parseEvents(_ d: Data) -> [FujiEvent] {
        guard let n = d.readLE16(at: 0) else { return [] }
        var out: [FujiEvent] = []
        var off = 2
        for _ in 0..<Int(n) {
            guard let code = d.readLE16(at: off), let value = d.readLE32(at: off + 2) else { break }
            out.append(FujiEvent(code: code, value: value))
            off += 6
        }
        return out
    }

    private func setU16(_ t: FujiIPTransport, _ prop: UInt32, _ value: UInt16,
                        timeout: TimeInterval, required: Bool) async throws {
        var d = Data(); d.appendLE(value)
        let r = try await t.send(PTPOp.setDevicePropValue, params: [prop], outData: d, timeout: timeout)
        log(String(format: "Set 0x%04X = %d: %@", prop, value, PTPResponse.name(r.code)))
        if required && !r.isOK { throw FujiWiFiFailure.step(String(format: "Setting 0x%04X", prop), r.code) }
    }

    /// Reads a property and writes the same value back as u32, as XApp does.
    private func echoProp(_ t: FujiIPTransport, _ prop: UInt32) async throws {
        let r = try await t.send(PTPOp.getDevicePropValue, params: [prop], outData: nil, timeout: 10)
        guard r.isOK else {
            log(String(format: "Get 0x%04X: %@ (skipped)", prop, PTPResponse.name(r.code)))
            return
        }
        let value: UInt32
        switch r.data.count {
        case 1: value = UInt32(r.data[r.data.startIndex])
        case 2: value = UInt32(r.data.readLE16(at: 0) ?? 0)
        default: value = r.data.readLE32(at: 0) ?? 0
        }
        var d = Data(); d.appendLE(value)
        let w = try await t.send(PTPOp.setDevicePropValue, params: [prop], outData: d, timeout: 10)
        log(String(format: "Echo 0x%04X = 0x%X: %@", prop, value, PTPResponse.name(w.code)))
    }

    private func shutdown(_ t: FujiIPTransport, liveViewTx: UInt32?) async {
        await Task.detached {
            if let tx = liveViewTx {
                let r = try? await t.send(PTPOp.terminateOpenCapture, params: [tx], outData: nil, timeout: 5)
                self.log("TerminateOpenCapture: \(r.map { PTPResponse.name($0.code) } ?? "no answer")")
            }
            await t.sendGoodbye()
        }.value
    }
}

func hex(_ d: Data) -> String {
    d.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ") + (d.count > 32 ? " …" : "")
}
