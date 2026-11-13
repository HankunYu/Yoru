import Foundation

/// Reads big-endian values from a buffer, failing rather than running off its end.
struct BinaryReader {
    let data: Data
    var offset = 0

    init(_ data: Data) {
        // Rebased, so offsets count from zero whatever slice was handed in.
        self.data = Data(data)
    }

    mutating func skip(_ count: Int) -> Bool {
        guard offset + count <= data.count else { return false }
        offset += count
        return true
    }

    mutating func uint8() -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint16() -> UInt16? {
        guard let high = uint8(), let low = uint8() else { return nil }
        return UInt16(high) << 8 | UInt16(low)
    }

    mutating func uint32() -> UInt32? {
        guard let high = uint16(), let low = uint16() else { return nil }
        return UInt32(high) << 16 | UInt32(low)
    }

    mutating func text(_ count: Int) -> String? {
        guard offset >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return String(data: data[offset..<offset + count], encoding: .ascii)
    }
}
