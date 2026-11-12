import Foundation
import Observation

/// A shortcut to a folder, shown on the browser's root screen.
struct Bookmark: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Where it leads: a server URL as it is (it names the server by identifier), or
    /// `local:` followed by a path relative to Documents. A local folder's absolute path
    /// changes whenever the app is reinstalled, so it is never stored.
    private let location: String

    private static let localPrefix = "local:"

    init(name: String, folder: URL) {
        id = UUID()
        self.name = name
        if folder.isFileURL {
            let root = URL.documentsDirectory.standardizedFileURL.path
            let path = folder.standardizedFileURL.path
            location = Self.localPrefix + (path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : "")
        } else {
            location = folder.absoluteString
        }
    }

    /// The folder's browser URL; nil if the location no longer makes one.
    var folder: URL? {
        if location.hasPrefix(Self.localPrefix) {
            return URL.documentsDirectory.appending(
                path: String(location.dropFirst(Self.localPrefix.count)), directoryHint: .isDirectory
            )
        }
        return URL(string: location)
    }
}

/// The saved bookmarks, persisted as JSON in Application Support.
@MainActor
@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()

    private(set) var bookmarks: [Bookmark] = []

    private static let fileURL = URL.applicationSupportDirectory.appending(path: "bookmarks.json")

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let bookmarks = try? JSONDecoder().decode([Bookmark].self, from: data) {
            self.bookmarks = bookmarks
        }
    }

    func bookmark(for folder: URL) -> Bookmark? {
        bookmarks.first { $0.folder.map(Self.key) == Self.key(folder) }
    }

    func bookmark(_ id: UUID) -> Bookmark? {
        bookmarks.first { $0.id == id }
    }

    func add(_ folder: URL, name: String) {
        guard bookmark(for: folder) == nil else { return }
        bookmarks.append(Bookmark(name: name, folder: folder))
        save()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[index].name = name
        save()
    }

    func remove(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    /// Drops the bookmarks that lead into a server being forgotten.
    func removeAll(inServer serverID: UUID) {
        bookmarks.removeAll { $0.folder.flatMap(MediaServer.parse)?.serverID == serverID }
        save()
    }

    /// Drops local bookmarks whose folder is gone. Server folders are not checked: that
    /// would take a connection per bookmark, and a server being offline proves nothing.
    func removeMissingLocalFolders() {
        let count = bookmarks.count
        bookmarks.removeAll { bookmark in
            guard let folder = bookmark.folder, folder.isFileURL else { return false }
            var isDirectory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue
        }
        if bookmarks.count != count {
            save()
        }
    }

    /// Two URLs of the same folder may differ in a trailing slash.
    private static func key(_ url: URL) -> String {
        let text = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(bookmarks).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.app.error("Saving bookmarks failed: \(error, privacy: .public)")
        }
    }
}
