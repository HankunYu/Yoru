import Foundation
import os

/// Whether a video can be played within the memory the system grants the app.
///
/// Playing holds a few dozen decoded frames at once: decoder threads, reference frames
/// and the display queue. At 8192×8192 that is several gigabytes, more than a phone gives
/// one app, and the system ends the app without a word. Declining to open such a video
/// keeps the app and says why.
enum PlaybackMemory {
    /// Frames held at once, measured on an iPhone with 4K to 8K video in software
    /// (VP8, VP9) and hardware (HEVC) decoding: footprint divided by the size of a frame.
    static let framesHeld = 36
    /// The share of the app's memory limit a video may plan to use.
    static let usableShare = 0.8

    /// The bytes playing a video of this size is expected to take.
    static func bytesNeeded(width: Int, height: Int, pixelFormat: String?) -> Int64 {
        // 4:2:0 with one byte a sample, or two for more than 8 bits.
        let isDeep = ["10", "12", "14", "16"].contains { pixelFormat?.contains($0) ?? false }
        let frame = Int64(width) * Int64(height) * 3 / 2 * (isDeep ? 2 : 1)
        return frame * Int64(framesHeld)
    }

    static func fits(width: Int, height: Int, pixelFormat: String?, limit: Int64?) -> Bool {
        // Nothing to hold the video against: let it play.
        guard let limit else { return true }
        return Double(bytesNeeded(width: width, height: height, pixelFormat: pixelFormat)) <= Double(limit) * usableShare
    }

    /// The most memory the system lets this app use: what it uses now and what it may
    /// still take. Nil where the system does not say, as in the simulator.
    static var limit: Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let available = Int64(os_proc_available_memory())
        guard result == KERN_SUCCESS, available > 0 else { return nil }
        return Int64(info.phys_footprint) + available
    }
}
