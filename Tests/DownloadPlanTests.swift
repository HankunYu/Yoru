import Foundation
import Testing
@testable import Yoru

/// A source serving a fixed tree, for walking without a network.
private struct FakeSource: MediaSource {
    /// Folder URL to the entries directly inside it.
    let tree: [URL: [BrowserItem]]
    let supportsDeletion = false

    static let root = URL(string: "yoru-dav://92e18282-8774-480c-85f6-f31e9cff34ee/")!

    static func file(_ name: String, in folder: URL, size: Int) -> BrowserItem {
        BrowserItem(url: folder.appending(component: name), kind: .file, name: name, size: size, modified: nil)
    }

    static func folder(_ name: String, in parent: URL) -> BrowserItem {
        BrowserItem(
            url: parent.appending(component: name, directoryHint: .isDirectory),
            kind: .folder, name: name, size: nil, modified: nil
        )
    }

    func contents(of directory: URL) async throws -> [BrowserItem] { tree[directory] ?? [] }
    func data(of url: URL) async throws -> Data { throw CocoaError(.fileNoSuchFile) }
    func delete(_ item: BrowserItem) throws {}
    func playback(of url: URL) -> PlaybackLocation { PlaybackLocation(location: url.absoluteString) }
    func transfer(of item: BrowserItem) -> FileTransfer? { nil }
}

@MainActor
struct DownloadPlanTests {
    private func finished(_ plan: DownloadPlan) async {
        while !plan.isComplete {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func series() -> (season: BrowserItem, source: FakeSource) {
        let season = FakeSource.folder("Season 1", in: FakeSource.root)
        let extras = FakeSource.folder("Extras", in: season.url)
        let source = FakeSource(tree: [
            season.url: [
                FakeSource.file("E01.mkv", in: season.url, size: 100),
                FakeSource.file("E02.mkv", in: season.url, size: 200),
                extras,
            ],
            extras.url: [FakeSource.file("Trailer.mkv", in: extras.url, size: 50)],
        ])
        return (season, source)
    }

    @Test func countsEverythingBelowTheSelection() async {
        let (season, source) = series()
        let loose = FakeSource.file("Loose.mkv", in: FakeSource.root, size: 7)
        let plan = DownloadPlan(items: [season, loose], source: source)
        await finished(plan)
        #expect(plan.fileCount == 4)
        #expect(plan.totalBytes == 357)
        #expect(plan.failure == nil)
    }

    @Test func skipsFilesTheTargetAlreadyHoldsAtTheSameSize() async {
        let (season, source) = series()
        let scratch = ScratchDirectory()
        scratch.write(String(repeating: "x", count: 100), to: "Season 1/E01.mkv")
        // A different size is an earlier, incomplete attempt: it is downloaded again.
        scratch.write("short", to: "Season 1/E02.mkv")

        let plan = DownloadPlan(items: [season], source: source)
        plan.target = scratch.url
        await finished(plan)

        #expect(plan.fileCount == 3)
        #expect(plan.remainingCount == 2)
        #expect(plan.remainingBytes == 250)
    }

    @Test func recountsWhenTheTargetChanges() async {
        let (season, source) = series()
        let holding = ScratchDirectory()
        holding.write(String(repeating: "x", count: 100), to: "Season 1/E01.mkv")
        let empty = ScratchDirectory()

        let plan = DownloadPlan(items: [season], source: source)
        await finished(plan)
        plan.target = holding.url
        #expect(plan.remainingCount == 2)
        plan.target = empty.url
        #expect(plan.remainingCount == 3)
    }
}
