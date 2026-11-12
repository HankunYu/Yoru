import Foundation

/// One entry in a browsed directory.
struct BrowserItem: Identifiable, Hashable {
    enum Kind: Int {
        case server
        /// A shortcut to a folder elsewhere; its `url` is that folder's.
        case bookmark
        case folder
        case file
    }

    /// Where the item lives; see `MediaSource` for the schemes.
    let url: URL
    let kind: Kind
    let name: String
    let size: Int?
    let modified: Date?
    /// Set for a bookmark: which one.
    var bookmarkID: UUID?

    var id: URL { url }
    var isDirectory: Bool { kind != .file }
    /// Meaningful for files only.
    var mediaKind: MediaKind { MediaKind(pathExtension: url.pathExtension) }
    /// The name as shown: files drop their extension, which moves to the detail line.
    var title: String { kind == .file ? (name as NSString).deletingPathExtension : name }

    init(url: URL, kind: Kind, name: String, size: Int?, modified: Date?) {
        self.url = url
        self.kind = kind
        self.name = name
        self.size = size
        self.modified = modified
    }

    init?(bookmark: Bookmark) {
        guard let folder = bookmark.folder else { return nil }
        self.init(url: folder, kind: .bookmark, name: bookmark.name, size: nil, modified: nil)
        bookmarkID = bookmark.id
    }

    init(server: MediaServer) {
        self.init(url: server.rootURL, kind: .server, name: server.name, size: nil, modified: nil)
    }
}

/// How the browser lays its items out.
enum BrowserViewMode: String, CaseIterable {
    case grid
    case list
}

/// How the browser orders items within each kind. Servers, bookmarks, then folders always
/// come first.
enum BrowserSortOrder: String, CaseIterable {
    case name
    /// Most recently modified first.
    case date
    /// Largest first.
    case size
}

extension [BrowserItem] {
    func sorted(by order: BrowserSortOrder) -> [BrowserItem] {
        sorted { $0.precedes($1, by: order) }
    }
}

private extension BrowserItem {
    func precedes(_ other: BrowserItem, by order: BrowserSortOrder) -> Bool {
        if kind != other.kind { return kind.rawValue < other.kind.rawValue }
        switch order {
        case .name:
            break
        case .date:
            // Folders have dates too; a server's shares and the servers themselves do not.
            if modified != other.modified { return (modified ?? .distantPast) > (other.modified ?? .distantPast) }
        case .size:
            // Only files have a size; folders stay in name order.
            if kind == .file, size != other.size { return (size ?? 0) > (other.size ?? 0) }
        }
        return name.localizedStandardCompare(other.name) == .orderedAscending
    }
}
