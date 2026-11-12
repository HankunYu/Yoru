import Foundation

/// A place media is browsed and played from. Every item is addressed by a URL whose scheme
/// names its source: `file` for the app's Documents, `yoru-smb` and `yoru-dav` for saved
/// servers (see `MediaServer`).
protocol MediaSource: Sendable {
    /// The entries of `directory`, in no particular order.
    func contents(of directory: URL) async throws -> [BrowserItem]
    var supportsDeletion: Bool { get }
    func delete(_ item: BrowserItem) throws
    /// How mpv opens the item at `url`.
    func playback(of url: URL) -> PlaybackLocation
    /// How to copy a file of this source into the local library; nil if it cannot be.
    func transfer(of item: BrowserItem) -> FileTransfer?
}

/// What to hand mpv to play an item.
struct PlaybackLocation {
    /// A file path or a URL mpv can open.
    var location: String
    /// Whether to turn mpv's cache on explicitly. It does so on its own for network URLs it
    /// opens itself, but streams served by the app look local to it.
    var forcesCache = false
    /// Request headers for HTTP locations (`http-header-fields`), e.g. authorization.
    var httpHeaders: [String] = []
}

enum MediaSources {
    static func source(for url: URL) -> any MediaSource {
        switch url.scheme {
        case MediaServer.Kind.smb.scheme: SMBSource()
        case MediaServer.Kind.webDAV.scheme: WebDAVSource()
        default: LocalSource()
        }
    }

    /// The URL schemes the app serves to mpv itself.
    static let streamProtocols: [String: MPVStreamOpener] = [
        MediaServer.Kind.smb.scheme: SMBSource.openStream,
    ]
}

// MARK: - Local files

struct LocalSource: MediaSource {
    let supportsDeletion = true

    func contents(of directory: URL) async throws -> [BrowserItem] {
        Self.items(in: directory)
    }

    func delete(_ item: BrowserItem) throws {
        try FileManager.default.removeItem(at: item.url)
    }

    func playback(of url: URL) -> PlaybackLocation {
        PlaybackLocation(location: url.path)
    }

    /// Local files are moved around, not downloaded.
    func transfer(of item: BrowserItem) -> FileTransfer? { nil }

    func rename(_ item: BrowserItem, to name: String) throws {
        try FileManager.default.moveItem(at: item.url, to: item.url.deletingLastPathComponent().appending(path: name))
    }

    func createFolder(named name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory.appending(path: name), withIntermediateDirectories: false)
    }

    /// Moves `items` into `folder`, keeping both when a name is already taken there.
    func move(_ items: [BrowserItem], into folder: URL) throws {
        for item in items where item.url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            try FileManager.default.moveItem(at: item.url, to: FileTransfers.availableURL(for: item.name, in: folder))
        }
    }

    /// Every folder of the library below `directory`, depth first, with its depth.
    static func folders(in directory: URL, depth: Int = 0) -> [(url: URL, depth: Int)] {
        items(in: directory)
            .filter { $0.kind == .folder }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .flatMap { [($0.url, depth)] + folders(in: $0.url, depth: depth + 1) }
    }

    /// The visible entries of `directory`, minus the mpv config directory, which is managed
    /// through Settings and the Files app rather than played from.
    static func items(in directory: URL) -> [BrowserItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.standardizedFileURL != ConfigDirectory.url.standardizedFileURL }
            .map { url in
                let values = try? url.resourceValues(forKeys: keys)
                return BrowserItem(
                    url: url,
                    kind: values?.isDirectory == true ? .folder : .file,
                    name: url.lastPathComponent,
                    size: values?.fileSize,
                    modified: values?.contentModificationDate
                )
            }
    }
}

// MARK: - SMB

/// Saved SMB servers, addressed as `yoru-smb://<server id>/<share>/<path>`.
///
/// The URL carries the server's identifier rather than its address and login, so nothing
/// secret ends up in mpv's logs or resume files; credentials are looked up when connecting.
struct SMBSource: MediaSource {
    let supportsDeletion = false

    /// mpv opens the browser URL itself, through `openStream`.
    func playback(of url: URL) -> PlaybackLocation {
        PlaybackLocation(location: url.absoluteString, forcesCache: true)
    }

    func transfer(of item: BrowserItem) -> FileTransfer? {
        guard item.kind == .file, let (serverID, path) = MediaServer.parse(item.url) else { return nil }
        return FileTransfer(name: item.name, totalBytes: Int64(item.size ?? 0)) { destination, progress in
            guard let credentials = SMBCredentials(serverID: serverID) else { throw SMBError(code: ENOENT) }
            let stream = try SMBStream(credentials: credentials, path: path)
            defer { stream.close() }
            let chunkSize = 1 << 20
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
            defer { buffer.deallocate() }
            try FileTransfer.write(to: destination, progress: progress) {
                let count = stream.read(into: buffer, count: chunkSize)
                guard count >= 0 else { throw SMBError(code: EIO) }
                return Data(bytes: buffer, count: count)
            }
        }
    }

    func contents(of directory: URL) async throws -> [BrowserItem] {
        guard let (serverID, path) = MediaServer.parse(directory) else { throw SMBError(code: ENOENT) }
        let entries = try await SMBSession.session(for: serverID).run { connection throws(SMBError) in
            path.isEmpty ? try connection.shares() : try connection.contents(of: path)
        }
        return entries.map { entry in
            BrowserItem(
                url: directory.appending(component: entry.name, directoryHint: entry.isDirectory ? .isDirectory : .notDirectory),
                kind: entry.isDirectory ? .folder : .file,
                name: entry.name,
                size: entry.size,
                modified: entry.modified
            )
        }
    }

    func delete(_ item: BrowserItem) throws {
        throw SMBError(code: ENOTSUP)
    }

    /// Opens a file for mpv. Runs on an mpv thread.
    static let openStream: MPVStreamOpener = { location in
        guard let url = URL(string: location), let (serverID, path) = MediaServer.parse(url),
              let credentials = SMBCredentials(serverID: serverID) else { return nil }
        do {
            return try SMBStream(credentials: credentials, path: path)
        } catch {
            Log.app.error("Opening an SMB stream failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

// MARK: - WebDAV

/// Saved WebDAV servers, addressed as `yoru-dav://<server id>/<path below the base URL>`.
///
/// Listing goes through `WebDAVClient`. Playback is mpv's own HTTP: it gets the file's real
/// URL, which holds no login, and the authorization as a request header.
struct WebDAVSource: MediaSource {
    let supportsDeletion = false

    func contents(of directory: URL) async throws -> [BrowserItem] {
        guard let (serverID, path) = MediaServer.parse(directory), let client = WebDAVClient(serverID: serverID) else {
            throw WebDAVError(reason: .notFound)
        }
        return try await client.contents(of: path).map { entry in
            BrowserItem(
                url: directory.appending(component: entry.name, directoryHint: entry.isDirectory ? .isDirectory : .notDirectory),
                kind: entry.isDirectory ? .folder : .file,
                name: entry.name,
                size: entry.size,
                modified: entry.modified
            )
        }
    }

    func delete(_ item: BrowserItem) throws {
        throw WebDAVError(reason: .status(405))
    }

    func transfer(of item: BrowserItem) -> FileTransfer? {
        guard item.kind == .file, let (serverID, path) = MediaServer.parse(item.url) else { return nil }
        return FileTransfer(name: item.name, totalBytes: Int64(item.size ?? 0)) { destination, progress in
            guard let client = WebDAVClient(serverID: serverID) else { throw WebDAVError(reason: .notFound) }
            try await client.download(path, to: destination, progress: progress)
        }
    }

    func playback(of url: URL) -> PlaybackLocation {
        guard let (serverID, path) = MediaServer.parse(url), let client = WebDAVClient(serverID: serverID),
              let location = client.url(for: path) else {
            return PlaybackLocation(location: url.absoluteString)
        }
        return PlaybackLocation(
            location: location.absoluteString,
            httpHeaders: client.authorization.map { ["Authorization: \($0)"] } ?? []
        )
    }
}
