import Foundation

/// Serves a stream from a few recently used blocks held in memory.
///
/// FFmpeg reads a file whose audio and video lie far apart by seeking between the two for
/// nearly every packet, and after each seek refills a buffer it sized for network input.
/// Straight through to a server that is megabytes fetched per packet. Here a seek only
/// moves a position, and each region mpv is reading keeps its own block, so the server
/// sees one sequential read per block however often mpv jumps.
final class BlockCachedStream: MPVStreamSource {
    static let defaultBlockSize = 1 << 20
    static let defaultBlockCount = 8

    private struct Block {
        var index: Int64
        var bytes: UnsafeMutableRawPointer
        /// Bytes held; less than a full block only at the end of the stream.
        var count: Int
        var lastUse: UInt64
    }

    private let source: any MPVStreamSource
    private let blockSize: Int
    private let blockCount: Int
    private var blocks: [Block] = []
    private var position: Int64 = 0
    /// Where the source's own position is, to skip seeks that would not move it.
    private var sourcePosition: Int64 = 0
    private var clock: UInt64 = 0
    private var knownSize: Int64??

    init(_ source: any MPVStreamSource, blockSize: Int = defaultBlockSize, blockCount: Int = defaultBlockCount) {
        self.source = source
        self.blockSize = blockSize
        self.blockCount = blockCount
    }

    deinit {
        for block in blocks {
            block.bytes.deallocate()
        }
    }

    var size: Int64? {
        if let knownSize { return knownSize }
        let size = source.size
        knownSize = size
        return size
    }

    func read(into buffer: UnsafeMutableRawPointer, count: Int) -> Int {
        guard count > 0, position >= 0 else { return 0 }
        let index = position / Int64(blockSize)
        guard let slot = slot(for: index) else { return -1 }
        let offset = Int(position - index * Int64(blockSize))
        // One block per call: mpv accepts a short read and asks again.
        let available = min(count, blocks[slot].count - offset)
        guard available > 0 else { return 0 }
        buffer.copyMemory(from: blocks[slot].bytes + offset, byteCount: available)
        position += Int64(available)
        return available
    }

    func seek(to offset: Int64) -> Bool {
        guard offset >= 0 else { return false }
        position = offset
        return true
    }

    func close() {
        source.close()
    }

    /// The position in `blocks` of block `index`, fetched first if it is not held.
    private func slot(for index: Int64) -> Int? {
        clock += 1
        if let slot = blocks.firstIndex(where: { $0.index == index }) {
            blocks[slot].lastUse = clock
            return slot
        }
        // Reuse the least recently used block's memory once the cache is full.
        var slot = blocks.count
        if blocks.count == blockCount, let oldest = blocks.indices.min(by: { blocks[$0].lastUse < blocks[$1].lastUse }) {
            slot = oldest
        }
        let bytes = slot < blocks.count ? blocks[slot].bytes : UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)
        let filled = fill(bytes, at: index * Int64(blockSize))
        let block = Block(index: index, bytes: bytes, count: max(filled, 0), lastUse: clock)
        if slot < blocks.count {
            blocks[slot] = block
        } else {
            blocks.append(block)
        }
        guard filled >= 0 else {
            // Nothing usable was read; keep the memory but not the contents.
            blocks[slot].index = -1
            return nil
        }
        return slot
    }

    /// Reads a whole block from the source. Returns the bytes read, short only at the end
    /// of the stream, or -1 if the source failed before giving any.
    private func fill(_ bytes: UnsafeMutableRawPointer, at offset: Int64) -> Int {
        if sourcePosition != offset {
            guard source.seek(to: offset) else {
                // The source's position is unknown now; force a seek next time.
                sourcePosition = -1
                return -1
            }
            sourcePosition = offset
        }
        var filled = 0
        while filled < blockSize {
            let read = source.read(into: bytes + filled, count: blockSize - filled)
            if read < 0 {
                sourcePosition = -1
                // A partial block would pass for the end of the stream.
                return -1
            }
            if read == 0 { break }
            filled += read
        }
        sourcePosition = offset + Int64(filled)
        return filled
    }
}
