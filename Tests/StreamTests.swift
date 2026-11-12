import Foundation
import Testing
@testable import Yoru

/// An in-memory source that counts what is asked of it.
private final class CountingSource: MPVStreamSource {
    let data: [UInt8]
    var offset = 0
    var seeks = 0
    var bytesRead = 0
    var failsReads = false
    /// The most one read returns, to exercise short reads.
    var chunk = Int.max

    init(count: Int) {
        data = (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) }
    }

    var size: Int64? { Int64(data.count) }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        if failsReads { return -1 }
        let length = min(count, chunk, data.count - offset)
        guard length > 0 else { return 0 }
        data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress! + offset, byteCount: length) }
        offset += length
        bytesRead += length
        return length
    }

    func seek(to offset: Int64) -> Bool {
        seeks += 1
        self.offset = Int(offset)
        return true
    }

    func close() {}
}

struct BlockCachedStreamTests {
    private func read(_ stream: BlockCachedStream, _ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let read = bytes.withUnsafeMutableBytes { stream.read(into: $0.baseAddress!, count: count) }
        return Array(bytes.prefix(max(read, 0)))
    }

    private func readAll(_ stream: BlockCachedStream, _ count: Int) -> [UInt8] {
        var result: [UInt8] = []
        while result.count < count {
            let part = read(stream, count - result.count)
            if part.isEmpty { break }
            result += part
        }
        return result
    }

    @Test func readsTheSameBytesAsTheSource() {
        let source = CountingSource(count: 1000)
        source.chunk = 7
        let stream = BlockCachedStream(source, blockSize: 64, blockCount: 2)
        #expect(readAll(stream, 5000) == source.data)
        #expect(read(stream, 10).isEmpty)
        #expect(source.seeks == 0)
    }

    @Test func alternatingRegionsCostOneReadPerBlock() {
        let source = CountingSource(count: 4096)
        let stream = BlockCachedStream(source, blockSize: 256, blockCount: 4)
        var low: Int64 = 0
        var high: Int64 = 3000
        for _ in 0..<50 {
            #expect(stream.seek(to: low))
            #expect(read(stream, 4) == Array(source.data[Int(low)..<Int(low) + 4]))
            low += 4
            #expect(stream.seek(to: high))
            #expect(read(stream, 4) == Array(source.data[Int(high)..<Int(high) + 4]))
            high += 4
        }
        // 200 bytes from each region: one block low, two high (3000 and 3072 onwards).
        #expect(source.bytesRead == 3 * 256)
        #expect(source.seeks <= 3)
    }

    @Test func returnsShortReadsAtBlockAndStreamEnds() {
        let source = CountingSource(count: 100)
        let stream = BlockCachedStream(source, blockSize: 64, blockCount: 2)
        #expect(stream.seek(to: 60))
        #expect(read(stream, 50).count == 4)
        #expect(read(stream, 50).count == 36)
        #expect(read(stream, 50).isEmpty)
        #expect(stream.seek(to: 500))
        #expect(read(stream, 50).isEmpty)
    }

    @Test func aFailedReadIsNotRememberedAsTheEnd() {
        let source = CountingSource(count: 100)
        let stream = BlockCachedStream(source, blockSize: 64, blockCount: 2)
        source.failsReads = true
        var byte: UInt8 = 0
        #expect(stream.read(into: &byte, count: 1) == -1)
        source.failsReads = false
        #expect(read(stream, 4) == Array(source.data[0..<4]))
    }
}
