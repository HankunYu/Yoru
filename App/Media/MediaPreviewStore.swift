import CryptoKit
import ImageIO
import UIKit
import UniformTypeIdentifiers
import os

/// Thumbnails and media facts for files, generated on demand and cached on disk.
///
/// Entries live in the Caches directory, keyed by location, size and modification date, so
/// a replaced file gets a new thumbnail and the system may reclaim the space at any time.
/// The store also keeps itself under `diskLimit`, dropping what was shown longest ago.
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
        forgetFailuresIfDecodersChanged()
        queue.addOperation { [self] in trim() }
    }

    // MARK: - Size limit

    /// The most the cache may take on disk; about ten thousand thumbnails.
    static let diskLimit: Int64 = 400 << 20
    /// Entries written between two checks of the size.
    private static let writesPerTrim = 64
    /// An entry's date moves when it is shown again, but not more often than this.
    private static let touchInterval: TimeInterval = 86_400
    private let writesSinceTrim = OSAllocatedUnfairLock(initialState: 0)

    /// One cached file: a thumbnail or the facts stored beside it, both named by `key`.
    struct CachedFile {
        var key: String
        var size: Int64
        var lastUse: Date
    }

    /// The keys to delete so that the files fit `limit`: the least recently used, down
    /// to a margin below the limit so the next writes do not trigger it again at once.
    static func keysToEvict(from files: [CachedFile], limit: Int64) -> [String] {
        var total = files.reduce(0) { $0 + $1.size }
        guard total > limit else { return [] }
        var entries: [String: (size: Int64, lastUse: Date)] = [:]
        for file in files {
            let entry = entries[file.key]
            entries[file.key] = (file.size + (entry?.size ?? 0), max(file.lastUse, entry?.lastUse ?? .distantPast))
        }
        var evicted: [String] = []
        for (key, entry) in entries.sorted(by: { ($0.value.lastUse, $0.key) < ($1.value.lastUse, $1.key) }) {
            guard total > limit * 4 / 5 else { break }
            total -= entry.size
            evicted.append(key)
        }
        return evicted
    }

    private func trim() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        let files = urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return CachedFile(
                key: url.deletingPathExtension().lastPathComponent,
                size: Int64(values?.fileSize ?? 0),
                lastUse: values?.contentModificationDate ?? .distantPast
            )
        }
        let evicted = Set(Self.keysToEvict(from: files, limit: Self.diskLimit))
        guard !evicted.isEmpty else { return }
        for url in urls where evicted.contains(url.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
        // Thumbnails still in memory stay usable; their files are made again if needed.
    }

    private func noteWrite() {
        let isDue = writesSinceTrim.withLock { count in
            count += 1
            guard count >= Self.writesPerTrim else { return false }
            count = 0
            return true
        }
        if isDue {
            trim()
        }
    }

    /// Marks a cached entry as used now, so trimming spares it.
    private func touch(_ infoURL: URL) {
        let modified = (try? infoURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified, Date().timeIntervalSince(modified) > Self.touchInterval else { return }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: infoURL.path)
    }

    /// Bumped whenever the bundled libmpv gains formats it can decode. Files remembered
    /// as having no picture get another try then; thumbnails that exist are kept.
    private static let decoderGeneration = 2
    private static let decoderGenerationKey = "previews.decoderGeneration"

    private func forgetFailuresIfDecodersChanged() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: Self.decoderGenerationKey) != Self.decoderGeneration else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let image = file.deletingPathExtension().appendingPathExtension("jpg")
            if !FileManager.default.fileExists(atPath: image.path) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        defaults.set(Self.decoderGeneration, forKey: Self.decoderGenerationKey)
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

    /// The preview if one exists already, in memory or on disk; never generates one, and
    /// does not wait behind generation, so it works while that is suspended.
    func existingPreview(for item: BrowserItem) async -> MediaPreview? {
        if let cached = cachedPreview(for: item) { return cached }
        return await Task.detached(priority: .userInitiated) { [self] in
            let key = cacheKey(for: item)
            guard let image = UIImage(contentsOfFile: directory.appending(path: key + ".jpg").path) else {
                return nil
            }
            let info = (try? Data(contentsOf: directory.appending(path: key + ".json")))
                .flatMap { try? JSONDecoder().decode(MediaInfo.self, from: $0) }
            return MediaPreview(image: image, info: info ?? MediaInfo())
        }.value
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
            touch(infoURL)
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
                noteWrite()
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
