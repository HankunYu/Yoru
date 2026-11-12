import Foundation

/// One entry in a browsed directory.
struct BrowserItem: Identifiable, Hashable {
    enum Kind: Int {
        case server
        case folder
        case file
    }

    /// Where the item lives; see `MediaSource` for the schemes.
    let url: URL
    let kind: Kind
    let name: String
    let size: Int?
    let modified: Date?

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

    init(server: SMBServer) {
        self.init(url: SMBSource.rootURL(for: server), kind: .server, name: server.name, size: nil, modified: nil)
    }
}

/// How the browser lays its items out.
enum BrowserViewMode: String, CaseIterable {
    case grid
    case list
}

/// How the browser orders files. Servers, then folders, always come first, sorted by name.
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
        if kind == .file {
            switch order {
            case .name:
                break
            case .date:
                if modified != other.modified { return (modified ?? .distantPast) > (other.modified ?? .distantPast) }
            case .size:
                if size != other.size { return (size ?? 0) > (other.size ?? 0) }
            }
        }
        return name.localizedStandardCompare(other.name) == .orderedAscending
    }
}
