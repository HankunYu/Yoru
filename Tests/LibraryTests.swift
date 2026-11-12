import Foundation
import Testing
@testable import Yoru

/// A scratch directory that removes itself.
final class ScratchDirectory {
    let url = URL.temporaryDirectory.appending(path: "yoru-test-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ contents: String, to name: String) -> URL {
        let file = url.appending(path: name)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

struct ResumePositionsTests {
    private let current = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    private let old = "11111111-2222-3333-4444-555555555555"

    private func path(_ container: String, _ file: String) -> String {
        "/private/var/mobile/Containers/Data/Application/\(container)/Documents/\(file)"
    }

    @Test func rekeysAnEntryFromAnOldContainer() throws {
        let scratch = ScratchDirectory()
        let stale = path(old, "Film.mkv")
        scratch.write("# \(stale)\nstart=120.5\nsid=2\n", to: ResumePositions.fileName(for: stale))

        ResumePositions.rebase(in: scratch.url, containerID: current)

        let moved = path(current, "Film.mkv")
        #expect(scratch.names == [ResumePositions.fileName(for: moved)])
        let text = try String(contentsOf: scratch.url.appending(path: ResumePositions.fileName(for: moved)), encoding: .utf8)
        #expect(text == "# \(moved)\nstart=120.5\nsid=2\n")
    }

    @Test func leavesCurrentAndRemoteEntriesAlone() {
        let scratch = ScratchDirectory()
        let local = path(current, "Film.mkv")
        let remote = "yoru-smb://92e18282-8774-480c-85f6-f31e9cff34ee/share/Film.mkv"
        scratch.write("# \(local)\nstart=5\n", to: ResumePositions.fileName(for: local))
        scratch.write("# \(remote)\nstart=7\n", to: ResumePositions.fileName(for: remote))

        ResumePositions.rebase(in: scratch.url, containerID: current)

        #expect(scratch.names == [ResumePositions.fileName(for: local), ResumePositions.fileName(for: remote)].sorted())
    }

    @Test func removesRedirectEntries() {
        let scratch = ScratchDirectory()
        scratch.write("# redirect entry\n", to: "0123456789ABCDEF0123456789ABCDEF")
        ResumePositions.rebase(in: scratch.url, containerID: current)
        #expect(scratch.names.isEmpty)
    }

    @Test func aPositionSavedSinceTheMoveWins() throws {
        let scratch = ScratchDirectory()
        let stale = path(old, "Film.mkv")
        let moved = path(current, "Film.mkv")
        scratch.write("# \(stale)\nstart=10\n", to: ResumePositions.fileName(for: stale))
        scratch.write("# \(moved)\nstart=99\n", to: ResumePositions.fileName(for: moved))

        ResumePositions.rebase(in: scratch.url, containerID: current)

        #expect(scratch.names == [ResumePositions.fileName(for: moved)])
        let text = try String(contentsOf: scratch.url.appending(path: ResumePositions.fileName(for: moved)), encoding: .utf8)
        #expect(text.contains("start=99"))
    }

    // mpv names the file by the upper-case MD5 of the path.
    @Test func namesFilesLikeMPV() {
        #expect(ResumePositions.fileName(for: "abc") == "900150983CD24FB0D6963F7D28E17F72")
    }
}

struct MediaServerTests {
    @Test func reducesTypedSMBAddressesToTheHost() {
        #expect(MediaServer.host(fromAddress: " nas.local ") == "nas.local")
        #expect(MediaServer.host(fromAddress: "smb://nas.local/share/folder") == "nas.local")
        #expect(MediaServer.host(fromAddress: "\\\\nas\\share") == "nas")
        #expect(MediaServer.host(fromAddress: "smb://user@192.168.1.2/") == "192.168.1.2")
    }

    @Test func completesWebDAVAddresses() {
        #expect(MediaServer.baseURL(fromAddress: "nas.local:5006/dav/") == "https://nas.local:5006/dav")
        #expect(MediaServer.baseURL(fromAddress: "http://nas.local:8080") == "http://nas.local:8080")
    }

    @Test func splitsBrowserURLs() throws {
        let server = MediaServer(id: UUID(), kind: .webDAV, name: "NAS", address: "https://nas", username: "")
        let folder = server.rootURL.appending(component: "动画 (2000)", directoryHint: .isDirectory)
            .appending(component: "第 #1 集.mkv", directoryHint: .notDirectory)
        let parsed = try #require(MediaServer.parse(folder))
        #expect(parsed.serverID == server.id)
        #expect(parsed.path == ["动画 (2000)", "第 #1 集.mkv"])
        #expect(MediaServer.parse(server.rootURL)?.path == [])
        #expect(MediaServer.parse(URL(filePath: "/tmp/a.mkv")) == nil)
    }

    // Servers saved before WebDAV existed have no kind and keep the address under "host".
    @Test func decodesServersSavedBeforeKindsExisted() throws {
        let json = #"[{"id":"92E18282-8774-480C-85F6-F31E9CFF34EE","name":"NAS","host":"nas.local","username":"me"}]"#
        let servers = try JSONDecoder().decode([MediaServer].self, from: Data(json.utf8))
        #expect(servers.first?.kind == .smb)
        #expect(servers.first?.address == "nas.local")
    }
}

struct BookmarkTests {
    @Test func keepsLocalFoldersRelativeToDocuments() throws {
        let folder = URL.documentsDirectory.appending(path: "Films/2021", directoryHint: .isDirectory)
        let bookmark = Bookmark(name: "2021", folder: folder)
        let data = try JSONEncoder().encode(bookmark)
        #expect(!String(decoding: data, as: UTF8.self).contains("Application"))
        let decoded = try JSONDecoder().decode(Bookmark.self, from: data)
        #expect(decoded.folder?.standardizedFileURL.path == folder.standardizedFileURL.path)
    }

    @Test func keepsServerFoldersAsTheyAre() {
        let url = URL(string: "yoru-smb://92e18282-8774-480c-85f6-f31e9cff34ee/share/Anime/")!
        #expect(Bookmark(name: "Anime", folder: url).folder == url)
    }
}

struct BrowserItemTests {
    private func file(_ name: String, size: Int = 0, modified: TimeInterval = 0) -> BrowserItem {
        BrowserItem(
            url: URL(filePath: "/tmp/\(name)"), kind: .file, name: name,
            size: size, modified: Date(timeIntervalSince1970: modified)
        )
    }

    private func folder(_ name: String, modified: TimeInterval = 0) -> BrowserItem {
        BrowserItem(
            url: URL(filePath: "/tmp/\(name)/"), kind: .folder, name: name,
            size: nil, modified: Date(timeIntervalSince1970: modified)
        )
    }

    @Test func foldersComeFirstAndNamesSortNaturally() {
        let items = [file("Episode 10.mkv"), file("Episode 2.mkv"), folder("Extras")]
        #expect(items.sorted(by: .name).map(\.name) == ["Extras", "Episode 2.mkv", "Episode 10.mkv"])
    }

    @Test func dateSortsNewestFirstIncludingFolders() {
        let items = [file("a.mkv", modified: 1), file("b.mkv", modified: 3), folder("old", modified: 1), folder("new", modified: 9)]
        #expect(items.sorted(by: .date).map(\.name) == ["new", "old", "b.mkv", "a.mkv"])
    }

    @Test func sizeSortsFilesLargestFirstAndLeavesFoldersByName() {
        let items = [file("small.mkv", size: 1), file("big.mkv", size: 9), folder("b"), folder("a")]
        #expect(items.sorted(by: .size).map(\.name) == ["a", "b", "big.mkv", "small.mkv"])
    }

    @Test func filesDropTheirExtensionInTheTitle() {
        #expect(file("Film.2021.mkv").title == "Film.2021")
        #expect(folder("Season.1").title == "Season.1")
    }

    @Test func aQueueHoldsOnlyFilesOfTheOpenedKind() {
        let items = [file("a.mkv"), file("a.chs.ass"), file("cover.jpg"), file("b.mp4"), file("song.flac"), folder("x")]
        let queue = PlaybackQueue(startingAt: items[0], among: items)
        #expect(queue.items.map(\.name) == ["a.mkv", "b.mp4"])
    }
}

struct WebDAVListingTests {
    @Test func parsesAMultistatusResponse() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/Anime/</d:href><d:propstat><d:prop>
            <d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
          <d:response><d:href>/dav/Anime/Season%201/</d:href><d:propstat><d:prop>
            <d:resourcetype><d:collection/></d:resourcetype>
            <d:getlastmodified>Thu, 12 Nov 2026 08:00:00 GMT</d:getlastmodified></d:prop></d:propstat></d:response>
          <d:response><d:href>http://nas/dav/Anime/%E6%B5%8B%E8%AF%95%20%231.mkv</d:href><d:propstat><d:prop>
            <d:resourcetype/><d:getcontentlength>1234</d:getcontentlength></d:prop></d:propstat></d:response>
          <d:response><d:href>/dav/Anime/.hidden</d:href><d:propstat><d:prop>
            <d:resourcetype/><d:getcontentlength>1</d:getcontentlength></d:prop></d:propstat></d:response>
        </d:multistatus>
        """
        let items = WebDAVListing.parse(Data(xml.utf8))
        #expect(items.map(\.entry.name) == ["Anime", "Season 1", "测试 #1.mkv"])
        #expect(items.map(\.entry.isDirectory) == [true, true, false])
        #expect(items[2].entry.size == 1234)
        #expect(items[1].entry.modified != nil)
        #expect(items[2].path == "/dav/Anime/测试 #1.mkv")
    }
}
