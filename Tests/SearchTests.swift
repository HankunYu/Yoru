import Foundation
import Testing
@testable import Yoru

/// A tree of folders held in memory.
private struct TreeSource: MediaSource {
    /// Folder path below the root ("" for the root) to the names in it; a name ending in
    /// a slash is a folder.
    let tree: [String: [String]]
    let root = URL(string: "yoru-smb://00000000-0000-0000-0000-000000000001")!
    let supportsDeletion = false

    func contents(of directory: URL) async throws -> [BrowserItem] {
        let path = directory.pathComponents.filter { $0 != "/" }.joined(separator: "/")
        guard let names = tree[path] else { throw CocoaError(.fileNoSuchFile) }
        return names.map { name in
            let isFolder = name.hasSuffix("/")
            let plain = isFolder ? String(name.dropLast()) : name
            return BrowserItem(
                url: directory.appending(component: plain, directoryHint: isFolder ? .isDirectory : .notDirectory),
                kind: isFolder ? .folder : .file, name: plain, size: nil, modified: nil
            )
        }
    }

    func delete(_ item: BrowserItem) throws {}
    func playback(of url: URL) -> PlaybackLocation { PlaybackLocation(location: url.absoluteString) }
    func transfer(of item: BrowserItem) -> FileTransfer? { nil }
}

struct SearchQueryTests {
    @Test func needsEveryTermInAnyOrder() {
        let query = SearchQuery("  spirited   2001 ")
        #expect(query.terms == ["spirited", "2001"])
        #expect(query.matches("Spirited Away (2001).mkv"))
        #expect(query.matches("2001 - SPIRITED away.mkv"))
        #expect(!query.matches("Spirited Away.mkv"))
    }

    @Test func ignoresCaseWidthAndAccents() {
        #expect(SearchQuery("amelie").matches("Amélie.mkv"))
        #expect(SearchQuery("千与").matches("千与千寻.mkv"))
        #expect(SearchQuery("ＡＢＣ").matches("abc.mp4"))
    }

    @Test func nothingTypedIsNoQuery() {
        #expect(SearchQuery("   ").isEmpty)
    }
}

@MainActor
struct FolderSearchTests {
    private let source = TreeSource(tree: [
        "": ["Films/", "Shows/", "cat.mkv", "notes.txt"],
        "Films": ["Cat Returns.mkv", "Old/"],
        "Films/Old": ["cat 1950.avi", "dog.avi"],
        "Shows": ["Locked/", "Catalogue/"],
        "Shows/Catalogue": ["e01.mkv"],
        // "Shows/Locked" is missing: a folder that cannot be read.
    ])

    @Test func findsMatchesBelowNearestFirstWithTheirPath() async {
        var found: [(name: String, context: String?)] = []
        var listed: [String] = []
        await FolderSearch(source: source, query: SearchQuery("cat")).run(from: source.root) { step in
            found += step.matches.map { ($0.name, $0.context) }
            listed.append(PlaybackQueue.folderKey(step.folder))
        }
        #expect(found.map(\.name) == ["cat.mkv", "Cat Returns.mkv", "Catalogue", "cat 1950.avi"])
        #expect(found.map(\.context) == [nil, "Films", "Shows", "Films/Old"])
        // The unreadable folder is passed over, the ones after it still searched.
        #expect(listed.count == 5)
    }

    @Test func queueFindsEachResultsOwnFolder() async {
        var results: [BrowserItem] = []
        var listings: [String: [BrowserItem]] = [:]
        await FolderSearch(source: source, query: SearchQuery("cat")).run(from: source.root) { step in
            results += step.matches
            listings[PlaybackQueue.folderKey(step.folder)] = step.listing
        }
        let first = results[0]
        let queue = PlaybackQueue(startingAt: first, among: results, listings: listings)
        // Videos among the results, folders left out.
        #expect(queue.items.map(\.name) == ["cat.mkv", "Cat Returns.mkv", "cat 1950.avi"])
        #expect(queue.siblings(of: queue.items[0]).map(\.name) == ["Films", "Shows", "cat.mkv", "notes.txt"])
        #expect(queue.siblings(of: queue.items[2]).map(\.name) == ["cat 1950.avi", "dog.avi"])
    }
}
