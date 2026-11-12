import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Thumbnails and media facts for local files, generated on demand and cached on disk.
///
/// Entries live in the Caches directory, keyed by path, size and modification date, so a
/// replaced file gets a new thumbnail and the system may reclaim the space at any time.
final class MediaPreviewStore: Sendable {
    static let shared = MediaPreviewStore()

    // One file at a time: each generation decodes video in software.
    private let queue = DispatchQueue(label: "com.hankunyu.Yoru.previews", qos: .utility)
    private let directory = URL.cachesDirectory.appending(path: "Previews", directoryHint: .isDirectory)
    // NSCache is thread-safe; the box makes the value an object.
    private nonisolated(unsafe) let memory = NSCache<NSString, Box>()

    private final class Box {
        let preview: MediaPreview
        init(_ preview: MediaPreview) { self.preview = preview }
    }

    private init() {
        memory.countLimit = 300
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The preview already held in memory, for showing a recycled cell without a flash.
    func cachedPreview(for url: URL) -> MediaPreview? {
        memory.object(forKey: url.path as NSString)?.preview
    }

    /// Loads the preview from the cache or generates it. Returns nil if the task was
    /// cancelled before its turn came.
    func preview(for url: URL) async -> MediaPreview? {
        if let cached = cachedPreview(for: url) { return cached }
        let task = Task.detached(priority: .utility) { [self] () -> MediaPreview? in
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(returning: Task.isCancelled ? nil : load(url))
                }
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Bytes the cached thumbnails take on disk.
    func diskUsage() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Deletes every cached thumbnail; they are generated again when next shown.
    func clear() {
        memory.removeAllObjects()
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Pauses generation, e.g. during playback, which should not compete for the CPU.
    /// Must be balanced by `resume()`.
    func suspend() { queue.suspend() }
    func resume() { queue.resume() }

    // MARK: - Private (runs on `queue`)

    private func load(_ url: URL) -> MediaPreview {
        let key = cacheKey(for: url)
        let imageURL = directory.appending(path: key + ".jpg")
        let infoURL = directory.appending(path: key + ".json")

        let preview: MediaPreview
        if let data = try? Data(contentsOf: infoURL), let info = try? JSONDecoder().decode(MediaInfo.self, from: data) {
            preview = MediaPreview(image: UIImage(contentsOfFile: imageURL.path)?.preparingForDisplay(), info: info)
        } else {
            let rendered = ThumbnailRenderer.render(path: url.path)
            if let image = rendered.image {
                write(image, to: imageURL)
            }
            // Written even without an image, so unreadable files are not retried every time.
            try? JSONEncoder().encode(rendered.info).write(to: infoURL)
            preview = MediaPreview(image: rendered.image.map { UIImage(cgImage: $0) }, info: rendered.info)
        }
        memory.setObject(Box(preview), forKey: url.path as NSString)
        return preview
    }

    private func cacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let identity = "\(url.path)|\(values?.fileSize ?? 0)|\(stamp)"
        return SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        CGImageDestinationFinalize(destination)
    }
}
