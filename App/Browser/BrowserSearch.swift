import Foundation

/// What typed text asks for: every word of it, somewhere in a name.
struct SearchQuery: Equatable, Sendable {
    let terms: [String]

    init(_ text: String) {
        terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Whether `name` holds every term, in any order; case, width and accents aside.
    func matches(_ name: String) -> Bool {
        terms.allSatisfy {
            name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }
}

/// Where a search looks.
enum SearchScope: Hashable {
    /// The folder being shown.
    case folder
    /// That folder and everything below it.
    case subfolders
}

/// Looks through a folder and all the folders below it, one listing at a time.
///
/// A server is asked for each folder in turn, which on a deep tree takes a while, so
/// results are handed over folder by folder and the walk stops when its task is cancelled.
struct FolderSearch: Sendable {
    /// One folder's worth: what it holds, and which of that matched.
    struct Step: Sendable {
        let folder: URL
        let listing: [BrowserItem]
        let matches: [BrowserItem]
    }

    /// Folders looked into before giving up, so a search cannot wander a huge tree forever.
    static let folderLimit = 3000

    let source: any MediaSource
    let query: SearchQuery

    /// Walks breadth first from `directory`: what is nearest is found first.
    func run(from directory: URL, report: @MainActor (Step) -> Void) async {
        var pending: [(url: URL, path: String)] = [(directory, "")]
        var visited = 0
        while !pending.isEmpty, visited < Self.folderLimit, !Task.isCancelled {
            let (url, path) = pending.removeFirst()
            visited += 1
            // A folder that cannot be read is passed over; the rest is still worth having.
            guard let listing = try? await source.contents(of: url), !Task.isCancelled else { continue }
            let matches = listing.filter { query.matches($0.name) }.map { item in
                var item = item
                item.context = path.isEmpty ? nil : path
                return item
            }
            await report(Step(folder: url, listing: listing, matches: matches))
            for folder in listing where folder.kind == .folder {
                pending.append((folder.url, path.isEmpty ? folder.name : path + "/" + folder.name))
            }
        }
    }
}
