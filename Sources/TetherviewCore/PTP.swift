// PTP (ISO 15740) building blocks: container encoding/decoding and the
// transport abstraction the Fujifilm live-view code runs on top of.
//
// Everything in this file is plain Foundation so it can be unit-tested on any
// platform. The iPhone transport (ImageCaptureCore) lives in the app target.

import Foundation

public enum PTPOp {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let getObjectHandles: UInt16 = 0x1007
    public static let getObject: UInt16 = 0x1009
    public static let deleteObject: UInt16 = 0x100B
    public static let getDevicePropValue: UInt16 = 0x1015
    public static let setDevicePropValue: UInt16 = 0x1016
    public static let terminateOpenCapture: UInt16 = 0x1018
    public static let initiateOpenCapture: UInt16 = 0x101C
}

public enum PTPResponse {
    public static let ok: UInt16 = 0x2001
    public static let generalError: UInt16 = 0x2002
    public static let sessionNotOpen: UInt16 = 0x2003
    public static let operationNotSupported: UInt16 = 0x2005
    public static let deviceBusy: UInt16 = 0x2019
    /// Fujifilm vendor code: refused in the camera's current state
    /// (e.g. a menu or playback is open on the body).
    public static let fujiRefusedInThisState: UInt16 = 0xA001
    /// Fujifilm vendor code: refused right now, try again shortly.
    public static let fujiRefusedRightNow: UInt16 = 0xA002

    public static func name(_ code: UInt16) -> String {
        switch code {
        case ok: return "OK"
        case generalError: return "GeneralError"
        case sessionNotOpen: return "SessionNotOpen"
        case operationNotSupported: return "OperationNotSupported"
        case 0x2006: return "ParameterNotSupported"
        case 0x2009: return "InvalidObjectHandle"
        case 0x200A: return "DevicePropNotSupported"
        case 0x2013: return "StoreNotAvailable"
        case deviceBusy: return "DeviceBusy"
        case 0x201D: return "InvalidParameter"
        case fujiRefusedInThisState: return "RefusedInThisState(Fuji)"
        case fujiRefusedRightNow: return "RefusedRightNow(Fuji)"
        default: return String(format: "0x%04X", code)
        }
    }
}

/// Result of one PTP transaction.
public struct PTPResult: Sendable {
    public var code: UInt16
    public var params: [UInt32]
    /// Data phase sent by the camera (payload only, no container header).
    public var data: Data

    public init(code: UInt16, params: [UInt32] = [], data: Data = Data()) {
        self.code = code
        self.params = params
        self.data = data
    }

    public var isOK: Bool { code == PTPResponse.ok }
}

public struct PTPError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Anything that can run a PTP transaction against a camera.
public protocol PTPTransport: AnyObject, Sendable {
    func send(_ opcode: UInt16, params: [UInt32], outData: Data?, timeout: TimeInterval) async throws -> PTPResult
}

public extension PTPTransport {
    func send(_ opcode: UInt16, params: [UInt32] = [], outData: Data? = nil) async throws -> PTPResult {
        try await send(opcode, params: params, outData: outData, timeout: 15)
    }
}

// MARK: - Container encoding

public enum PTPContainer {
    public static let typeCommand: UInt16 = 1
    public static let typeData: UInt16 = 2
    public static let typeResponse: UInt16 = 3
    public static let typeEvent: UInt16 = 4
    public static let headerSize = 12

    /// Command block: length(4) type(2) code(2) transactionID(4) params(4 each).
    public static func command(opcode: UInt16, transactionID: UInt32, params: [UInt32]) -> Data {
        precondition(params.count <= 5, "PTP allows at most 5 parameters")
        var d = Data()
        d.appendLE(UInt32(headerSize + params.count * 4))
        d.appendLE(typeCommand)
        d.appendLE(opcode)
        d.appendLE(transactionID)
        for p in params { d.appendLE(p) }
        return d
    }

    /// Parses a response block into (code, params). Returns nil if malformed.
    public static func parseResponse(_ block: Data?) -> (code: UInt16, params: [UInt32])? {
        guard let block = block, block.count >= headerSize else { return nil }
        let length = Int(block.readLE32(at: 0) ?? 0)
        guard let code = block.readLE16(at: 6) else { return nil }
        let end = min(block.count, max(headerSize, length))
        var params: [UInt32] = []
        var off = headerSize
        while off + 4 <= end, params.count < 5 {
            if let v = block.readLE32(at: off) { params.append(v) }
            off += 4
        }
        return (code, params)
    }

    /// ImageCaptureCore normally hands back the bare data-phase payload, but be
    /// defensive: if it looks like a full data container, strip the header.
    public static func stripDataHeaderIfPresent(_ data: Data) -> Data {
        guard data.count >= headerSize,
              let len = data.readLE32(at: 0),
              let type = data.readLE16(at: 4),
              type == typeData,
              Int(len) == data.count
        else { return data }
        return data.subdata(in: data.startIndex.advanced(by: headerSize)..<data.endIndex)
    }

    /// PTP array of UINT32 (count followed by elements), e.g. GetObjectHandles.
    public static func parseUInt32Array(_ data: Data) -> [UInt32] {
        guard let count = data.readLE32(at: 0) else { return [] }
        var out: [UInt32] = []
        let n = min(Int(count), (data.count - 4) / 4)
        guard n > 0 else { return [] }
        out.reserveCapacity(n)
        for i in 0..<n {
            if let v = data.readLE32(at: 4 + i * 4) { out.append(v) }
        }
        return out
    }
}

// MARK: - Little-endian helpers

public extension Data {
    mutating func appendLE(_ v: UInt16) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLE16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let i = startIndex.advanced(by: offset)
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    func readLE32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let i = startIndex.advanced(by: offset)
        return UInt32(self[i])
            | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16)
            | (UInt32(self[i + 3]) << 24)
    }
}
