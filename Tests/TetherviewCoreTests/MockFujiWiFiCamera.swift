import Foundation
@testable import TetherviewCore

/// Simulates a Fujifilm body's Wi-Fi PTP/IP server (command, event and
/// live-view sockets), following libfuji's description of the XApp flow.
final class MockFujiWiFiCamera: @unchecked Sendable {
    let lock = NSLock()
    var props: [UInt32: Data] = [:]
    var eventPollsBeforeAccess = 2
    var eventPolls = 0
    var sessionOpenedWithTx: UInt32?
    var propWrites: [(UInt32, Data)] = []
    var liveView = false
    var terminatedTx: UInt32?
    var initiateTx: UInt32?
    var gotGoodbye = false
    var refuseInit = false
    var frameCounter: UInt32 = 0
    private var videoServer: MemoryStream?

    init() {
        func u32(_ v: UInt32) -> Data { var d = Data(); d.appendLE(v); return d }
        func u16(_ v: UInt16) -> Data { var d = Data(); d.appendLE(v); return d }
        props[FujiIP.getObjectVersion] = u32(4)
        props[FujiIP.remoteGetObjectVersion] = u32(5)
        props[FujiIP.imageGetVersion] = u32(3)
        props[FujiIP.remoteVersion] = u32(0x2000C)
        props[FujiIP.remotePhotoViewExVersion] = u32(2)
        props[FujiIP.unknownDF2A] = u16(1)
        props[FujiIP.cameraState] = u16(0)
        props[FujiIP.clientState] = u16(0)
    }

    /// Stream opener to hand to FujiWiFiLiveView.
    var opener: StreamOpener {
        { [self] port in
            let (client, server) = MemoryStream.pair()
            switch port {
            case FujiIP.commandPort:
                Task { await self.serveCommands(server) }
            case FujiIP.liveViewPort:
                lock.lock(); videoServer = server; lock.unlock()
                Task { await self.serveVideo(server) }
            case FujiIP.eventPort:
                break
            default:
                throw PTPError("connection refused")
            }
            return client
        }
    }

    private func serveCommands(_ s: MemoryStream) async {
        do {
            let initPacket = try await s.receive(exactly: 0x52, timeout: 5)
            guard initPacket.readLE32(at: 8) == FujiIP.protocolVersion else { s.close(); return }
            var ack = Data()
            if refuseInit {
                ack.appendLE(UInt32(12)); ack.appendLE(FujiIP.initFail); ack.appendLE(UInt32(0x2019))
                try await s.send(ack)
                s.close()
                return
            }
            ack.appendLE(UInt32(0x44)); ack.appendLE(FujiIP.initAck)
            for _ in 0..<5 { ack.appendLE(UInt32(0x1234)) }
            for u in "X-T50".utf16 { ack.appendLE(u) }
            ack.append(Data(count: 0x44 - ack.count))
            try await s.send(ack)

            while true {
                let lenData = try await s.receive(exactly: 4, timeout: 30)
                let len = Int(lenData.readLE32(at: 0)!)
                let rest = try await s.receive(exactly: len - 4, timeout: 5)
                if len == 8 && rest == Data([0xFF, 0xFF, 0xFF, 0xFF]) {
                    lock.lock(); gotGoodbye = true; lock.unlock()
                    return
                }
                let packet = lenData + rest
                let code = packet.readLE16(at: 6)!
                let tx = packet.readLE32(at: 8)!
                var params: [UInt32] = []
                var off = 12
                while off + 4 <= packet.count { params.append(packet.readLE32(at: off)!); off += 4 }

                var outData: Data?
                if code == PTPOp.setDevicePropValue {
                    let dl = try await s.receive(exactly: 4, timeout: 5)
                    let drest = try await s.receive(exactly: Int(dl.readLE32(at: 0)!) - 4, timeout: 5)
                    outData = Data((dl + drest).dropFirst(12))
                }
                let (rc, data) = handle(code: code, tx: tx, params: params, outData: outData)
                var reply = Data()
                if let data = data {
                    reply.appendLE(UInt32(12 + data.count)); reply.appendLE(UInt16(2))
                    reply.appendLE(code); reply.appendLE(tx); reply.append(data)
                }
                reply.appendLE(UInt32(12)); reply.appendLE(UInt16(3)); reply.appendLE(rc); reply.appendLE(tx)
                try await s.send(reply)
            }
        } catch {
            return
        }
    }

    private func handle(code: UInt16, tx: UInt32, params: [UInt32], outData: Data?) -> (UInt16, Data?) {
        lock.lock(); defer { lock.unlock() }
        switch code {
        case FujiIP.openSession:
            sessionOpenedWithTx = tx
            return (PTPResponse.ok, nil)
        case PTPOp.getDevicePropValue:
            let p = params.first ?? 0
            if p == FujiIP.eventsList {
                eventPolls += 1
                var d = Data()
                d.appendLE(UInt16(1))
                d.appendLE(UInt16(FujiIP.cameraState))
                d.appendLE(UInt32(eventPolls > eventPollsBeforeAccess ? 2 : 0))
                return (PTPResponse.ok, d)
            }
            if let v = props[p] { return (PTPResponse.ok, v) }
            return (0x200A, nil)
        case PTPOp.setDevicePropValue:
            let p = params.first ?? 0
            let v = outData ?? Data()
            propWrites.append((p, v))
            if p == FujiIP.clientState, v.readLE16(at: 0) == FujiIP.clientXAppLiveView,
               props[FujiIP.cameraState]?.readLE16(at: 0) != FujiIP.cameraStateRemote {
                return (PTPResponse.deviceBusy, nil)
            }
            props[p] = v
            return (PTPResponse.ok, nil)
        case PTPOp.initiateOpenCapture:
            guard props[FujiIP.clientState]?.readLE16(at: 0) == FujiIP.clientXAppLiveView else {
                return (PTPResponse.fujiRefusedInThisState, nil)
            }
            liveView = true
            initiateTx = tx
            return (PTPResponse.ok, nil)
        case PTPOp.terminateOpenCapture:
            terminatedTx = params.first
            liveView = false
            return (PTPResponse.ok, nil)
        default:
            return (PTPResponse.ok, nil)
        }
    }

    private func serveVideo(_ s: MemoryStream) async {
        while true {
            lock.lock()
            let on = liveView
            frameCounter &+= 1
            let n = frameCounter
            lock.unlock()
            if on {
                let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, UInt8(n & 0xFF), 0xFF, 0xD9])
                var frame = Data()
                frame.appendLE(UInt32(18 + jpeg.count))
                frame.appendLE(UInt32(0)); frame.appendLE(n)
                frame.append(Data(count: 6))
                frame.append(jpeg)
                do { try await s.send(frame) } catch { return }
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
