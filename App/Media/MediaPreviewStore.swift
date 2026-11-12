import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers
import os

/// Thumbnails and media facts for files, generated on demand and cached on disk.
///
/// Entries live in the Caches directory, keyed by location, size and modification date, so
/// a replaced file gets a new thumbnail and the system may reclaim the space at any time.
final class MediaPreviewStore: Sendable {
    static let shared = MediaPreviewStore()

    // A few files at a time. Each generation runs its own mpv instance and decodes in
    // software, so the limit keeps memory and heat in check.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.hankunyu.Yoru.previews"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private let suspensions = OSAllocatedUnfairLock(initialState: 0)
    private let directory = URL.cachesDirectory.appending(path: "Previews", directoryHint: .isDirectory)
    // NSCache is thread-safe; the box makes the value an object.
    private nonisolated(unsafe) let memory = NSCache<NSString, Box>()
    private let rendersRemote = OSAllocatedUnfairLock(initialState: YoruOptions.load().remoteThumbnails)

    private final class Box {
        let preview: MediaPreview
        init(_ preview: MediaPreview) { self.preview = preview }
    }

    private init() {
        memory.countLimit = 300
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Whether files on servers get thumbnails. Each one costs a connection and a few
    /// megabytes of reading, so it can be turned off.
    var rendersRemoteFiles: Bool {
        get { rendersRemote.withLock { $0 } }
        set { rendersRemote.withLock { $0 = newValue } }
    }

    /// Whether `item` is something a thumbnail is made for at all.
    func isEligible(_ item: BrowserItem) -> Bool {
        if item.url.isFileURL { return true }
        // Remote files are only worth the transfer when they have a picture.
        return rendersRemoteFiles && (item.mediaKind == .video || item.mediaKind == .image)
    }

    /// The preview already held in memory, for showing a recycled cell without a flash.
    func cachedPreview(for item: BrowserItem) -> MediaPreview? {
        memory.object(forKey: item.url.absoluteString as NSString)?.preview
    }

    /// Loads the preview from the cache or generates it. Returns nil if the item is not
    /// eligible, or the task was cancelled before its turn came.
    func preview(for item: BrowserItem) async -> MediaPreview? {
        guard isEligible(item) else { return nil }
        if let cached = cachedPreview(for: item) { return cached }
        let task = Task.detached(priority: .utility) { [self] () -> MediaPreview? in
            await withCheckedContinuation { continuation in
                queue.addOperation { [self] in
                    continuation.resume(returning: Task.isCancelled ? nil : load(item))
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
    func suspend() {
        suspensions.withLock { count in
            count += 1
            queue.isSuspended = true
        }
    }

    func resume() {
        suspensions.withLock { count in
            count -= 1
            queue.isSuspended = count > 0
        }
    }

    // MARK: - Private (runs on `queue`, several at once)

    private func load(_ item: BrowserItem) -> MediaPreview {
        let key = cacheKey(for: item)
        let imageURL = directory.appending(path: key + ".jpg")
        let infoURL = directory.appending(path: key + ".json")

        let preview: MediaPreview
        if let data = try? Data(contentsOf: infoURL), let info = try? JSONDecoder().decode(MediaInfo.self, from: data) {
            preview = MediaPreview(image: UIImage(contentsOfFile: imageURL.path)?.preparingForDisplay(), info: info)
        } else {
            let playback = MediaSources.source(for: item.url).playback(of: item.url)
            let rendered = ThumbnailRenderer.render(playback)
            if let image = rendered.image {
                write(image, to: imageURL)
            }
            // A result without an image is remembered too, so unreadable files are not
            // retried every time. Not for a remote file that never opened, though: that
            // may have been the network, and is worth another try.
            if rendered.image != nil || rendered.info.duration != nil || item.url.isFileURL {
                try? JSONEncoder().encode(rendered.info).write(to: infoURL)
            }
            preview = MediaPreview(image: rendered.image.map { UIImage(cgImage: $0) }, info: rendered.info)
        }
        memory.setObject(Box(preview), forKey: item.url.absoluteString as NSString)
        return preview
    }

    private func cacheKey(for item: BrowserItem) -> String {
        let location: String
        if item.url.isFileURL {
            // Relative to the app's container: its absolute path changes whenever the app
            // is reinstalled, which would orphan every cached entry.
            let home = URL.homeDirectory.resolvingSymlinksInPath().path
            let path = item.url.resolvingSymlinksInPath().path
            location = path.hasPrefix(home) ? String(path.dropFirst(home.count)) : path
        } else {
            location = item.url.absoluteString
        }
        let stamp = item.modified?.timeIntervalSince1970 ?? 0
        let identity = "\(ThumbnailRenderer.version)|\(location)|\(item.size ?? 0)|\(stamp)"
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
