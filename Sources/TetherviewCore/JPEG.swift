import Foundation

public enum JPEG {
    /// Returns the JPEG inside `data`: from the first SOI marker (FF D8 FF) to
    /// the last EOI marker (FF D9). Fujifilm preview objects are normally a
    /// bare JPEG, but some bodies prepend a small header, so search for it.
    public static func extract(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        var soi: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0xFF, bytes[i + 1] == 0xD8, bytes[i + 2] == 0xFF {
                soi = i
                break
            }
            i += 1
        }
        guard let start = soi else { return nil }

        var end: Int?
        var j = bytes.count - 2
        while j > start {
            if bytes[j] == 0xFF, bytes[j + 1] == 0xD9 {
                end = j + 2
                break
            }
            j -= 1
        }
        // A frame with no EOI is truncated; show it anyway — decoders cope
        // and a slightly broken frame beats a frozen one.
        let stop = end ?? bytes.count
        return Data(bytes[start..<stop])
    }
}
