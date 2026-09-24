import Foundation

/// The parts of a PTP DeviceInfo dataset we care about.
public struct PTPDeviceInfo: Sendable {
    public var vendorExtensionID: UInt32 = 0
    public var vendorExtensionDesc: String = ""
    public var functionalMode: UInt16 = 0
    public var operations: [UInt16] = []
    public var events: [UInt16] = []
    public var properties: [UInt16] = []
    public var manufacturer: String = ""
    public var model: String = ""
    public var deviceVersion: String = ""

    public init() {}

    public func supports(operation op: UInt16) -> Bool { operations.contains(op) }
    public func supports(property p: UInt16) -> Bool { properties.contains(p) }

    /// Parses a DeviceInfo dataset (ISO 15740 §5.5.1). Returns nil when the
    /// data is too short to be one.
    public static func parse(_ data: Data) -> PTPDeviceInfo? {
        var r = PTPReader(data)
        var info = PTPDeviceInfo()
        guard r.u16() != nil,                        // StandardVersion
              let ext = r.u32(),
              r.u16() != nil                         // VendorExtensionVersion
        else { return nil }
        info.vendorExtensionID = ext
        info.vendorExtensionDesc = r.string() ?? ""
        info.functionalMode = r.u16() ?? 0
        info.operations = r.u16Array() ?? []
        info.events = r.u16Array() ?? []
        info.properties = r.u16Array() ?? []
        _ = r.u16Array()                             // CaptureFormats
        _ = r.u16Array()                             // ImageFormats
        info.manufacturer = r.string() ?? ""
        info.model = r.string() ?? ""
        info.deviceVersion = r.string() ?? ""
        return info
    }
}

/// Sequential little-endian reader for PTP datasets.
public struct PTPReader {
    private let data: Data
    public private(set) var offset = 0

    public init(_ data: Data) { self.data = data }

    public mutating func u8() -> UInt8? {
        guard offset + 1 <= data.count else { return nil }
        defer { offset += 1 }
        return data[data.startIndex.advanced(by: offset)]
    }

    public mutating func u16() -> UInt16? {
        guard let v = data.readLE16(at: offset) else { return nil }
        offset += 2
        return v
    }

    public mutating func u32() -> UInt32? {
        guard let v = data.readLE32(at: offset) else { return nil }
        offset += 4
        return v
    }

    public mutating func u16Array() -> [UInt16]? {
        guard let n = u32() else { return nil }
        guard Int(n) <= (data.count - offset) / 2 else { return nil }
        var out: [UInt16] = []
        out.reserveCapacity(Int(n))
        for _ in 0..<Int(n) {
            guard let v = u16() else { return nil }
            out.append(v)
        }
        return out
    }

    /// PTP string: UINT8 number of UTF-16 code units (including the
    /// terminating NUL), then the code units.
    public mutating func string() -> String? {
        guard let n = u8() else { return nil }
        if n == 0 { return "" }
        var units: [UInt16] = []
        for _ in 0..<Int(n) {
            guard let c = u16() else { return nil }
            units.append(c)
        }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}
