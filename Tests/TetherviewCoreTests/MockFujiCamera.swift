import Foundation
@testable import TetherviewCore

/// Simulates the Fujifilm USB tether behaviour described in FujiLiveView.swift.
final class MockFujiCamera: PTPTransport, @unchecked Sendable {
    let lock = NSLock()
    var tetherMode = true
    var requiresControlToStream = false
    var priority: UInt16 = Fuji.priorityCamera
    var streaming = false
    var nextHandle: UInt32 = 0x100
    var liveHandles: [UInt32] = []
    var frameCounter: UInt8 = 0
    var log: [String] = []
    var priorityWrites: [UInt16] = []
    var terminateCount = 0

    func send(_ opcode: UInt16, params: [UInt32], outData: Data?, timeout: TimeInterval) async throws -> PTPResult {
        lock.lock(); defer { lock.unlock() }
        log.append(String(format: "%04X", opcode))
        switch opcode {
        case PTPOp.getDeviceInfo:
            return PTPResult(code: PTPResponse.ok, data: deviceInfo())

        case PTPOp.initiateOpenCapture:
            if requiresControlToStream && priority != Fuji.priorityHost {
                return PTPResult(code: PTPResponse.fujiRefusedInThisState)
            }
            streaming = true
            return PTPResult(code: PTPResponse.ok)

        case PTPOp.terminateOpenCapture:
            terminateCount += 1
            streaming = false
            liveHandles.removeAll()
            return PTPResult(code: PTPResponse.ok)

        case PTPOp.getDevicePropValue:
            guard params.first == Fuji.propPriorityMode else { return PTPResult(code: 0x200A) }
            var d = Data(); d.appendLE(priority)
            return PTPResult(code: PTPResponse.ok, data: d)

        case PTPOp.setDevicePropValue:
            guard params.first == Fuji.propPriorityMode, let v = outData?.readLE16(at: 0) else {
                return PTPResult(code: 0x200A)
            }
            if v == priority { return PTPResult(code: PTPResponse.fujiRefusedRightNow) }
            priority = v
            priorityWrites.append(v)
            return PTPResult(code: PTPResponse.ok)

        case PTPOp.getObjectHandles:
            guard params.first == Fuji.liveStore else { return PTPResult(code: 0x2013) }
            if streaming {
                // A new preview appears on every poll, and stale ones remain
                // until deleted.
                liveHandles.append(nextHandle)
                nextHandle += 1
            }
            var d = Data(); d.appendLE(UInt32(liveHandles.count))
            for h in liveHandles { d.appendLE(h) }
            return PTPResult(code: PTPResponse.ok, data: d)

        case PTPOp.getObject:
            guard let h = params.first, liveHandles.contains(h) else { return PTPResult(code: 0x2009) }
            frameCounter &+= 1
            // 6-byte junk header, then a tiny "JPEG".
            let bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 0xFF, 0xD8, 0xFF, 0xE0, frameCounter, 0xFF, 0xD9]
            return PTPResult(code: PTPResponse.ok, data: Data(bytes))

        case PTPOp.deleteObject:
            guard let h = params.first else { return PTPResult(code: 0x201D) }
            liveHandles.removeAll { $0 == h }
            return PTPResult(code: PTPResponse.ok)

        default:
            return PTPResult(code: PTPResponse.operationNotSupported)
        }
    }

    func deviceInfo() -> Data {
        var ops: [UInt16] = [PTPOp.getDeviceInfo, PTPOp.getObjectHandles, PTPOp.getObject, PTPOp.deleteObject,
                             PTPOp.getDevicePropValue, PTPOp.setDevicePropValue]
        if tetherMode { ops += [PTPOp.initiateOpenCapture, PTPOp.terminateOpenCapture] }
        return MockFujiCamera.buildDeviceInfo(model: "X-T50", ops: ops, props: [0xD207, 0xD208])
    }

    static func buildDeviceInfo(model: String, ops: [UInt16], props: [UInt16]) -> Data {
        var d = Data()
        d.appendLE(UInt16(100))                 // StandardVersion
        d.appendLE(Fuji.vendorExtensionID)      // VendorExtensionID
        d.appendLE(UInt16(100))                 // VendorExtensionVersion
        appendString(&d, "fujifilm.co.jp: 1.0;")
        d.appendLE(UInt16(0))                   // FunctionalMode
        appendArray(&d, ops)
        appendArray(&d, [0xC001])               // Events
        appendArray(&d, props)
        appendArray(&d, [])                     // CaptureFormats
        appendArray(&d, [0x3801])               // ImageFormats
        appendString(&d, "FUJIFILM")
        appendString(&d, model)
        appendString(&d, "1.10")
        appendString(&d, "SERIAL")
        return d
    }

    static func appendArray(_ d: inout Data, _ a: [UInt16]) {
        d.appendLE(UInt32(a.count))
        for v in a { d.appendLE(v) }
    }

    static func appendString(_ d: inout Data, _ s: String) {
        let units = Array(s.utf16) + [0]
        d.append(UInt8(units.count))
        for u in units { d.appendLE(u) }
    }
}
