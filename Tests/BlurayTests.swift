import Foundation
import Testing
@testable import Yoru

struct BlurayPlaylistTests {
    /// A playlist of three clips with five chapter marks, the third clip entered 5 s in.
    private static let sample = Data(hex: """
    4d504c53303230300000003a000001fd0000000000000000000000000000000000000000000000000000000e\
    0000000000000000000000000000000001bf000000030000009130303030314d325453000100019bfcc001b0\
    9630000000000000000000000000006f000001020300000000000000000009011011000000000000051b6200\
    0000090111000000000000000586616a706e09011101000000000000058031656e6709011200000000000000\
    05907a686f000901120100000000000005907a686f0009011202000000000000069201656e67000091303030\
    30324d325453000100019bfcc001b77400000000000000000000000000006f00000102030000000000000000\
    0009011011000000000000051b62000000090111000000000000000586616a706e0901110100000000000005\
    8031656e670901120000000000000005907a686f000901120100000000000005907a686f0009011202000000\
    000000069201656e6700009130303030334d325453000100019f6ba801b40518000000000000000000000000\
    006f000001020300000000000000000009011011000000000000051b62000000090111000000000000000586\
    616a706e09011101000000000000058031656e670901120000000000000005907a686f000901120100000000\
    000005907a686f0009011202000000000000069201656e670000000048000500010000019bfcc0ffff000000\
    000001000001a64978ffff0000000000010001019bfcc0ffff0000000000010002019f6ba8ffff0000000000\
    01000201a9b860ffff00000000
    """)

    @Test func readsClipsInOrderWithTheirStretches() throws {
        let playlist = try #require(BlurayPlaylist(data: Self.sample, name: "00800"))
        #expect(playlist.items.map(\.clip) == ["00001", "00002", "00003"])
        #expect(playlist.items.map(\.start) == [600, 600, 605])
        #expect(playlist.items.map(\.duration) == [30, 40, 30])
        #expect(playlist.duration == 100)
    }

    @Test func placesChaptersOnTheTitlesOwnTimeline() throws {
        let playlist = try #require(BlurayPlaylist(data: Self.sample, name: "00800"))
        // Marks at the start and 15 s into clip 1, the start of clip 2, and in clip 3 at
        // its entry point and 15 s after it.
        #expect(playlist.chapters == [0, 15, 30, 70, 85])
    }

    /// The same title with a second angle on its first clip, which moves the stream table.
    private static let multiAngle = Data(hex: """
    4d504c53303230300000003a000002090000000000000000000000000000000000000000000000000000000e\
    0000000000000000000000000000000001cb000000030000009d30303030314d325453001100019bfcc001b0\
    9630000000000000000000000000020030303039394d32545300006f00000102030000000000000000000901\
    1011000000000000051b62000000090111000000000000000586616a706e0901110100000000000005803165\
    6e670901120000000000000005907a686f000901120100000000000005907a686f0009011202000000000000\
    069201656e6700009130303030324d325453000100019bfcc001b77400000000000000000000000000006f00\
    0001020300000000000000000009011011000000000000051b62000000090111000000000000000586616a70\
    6e09011101000000000000058031656e670901120000000000000005907a686f000901120100000000000005\
    907a686f0009011202000000000000069201656e6700009130303030334d325453000100019f6ba801b40518\
    000000000000000000000000006f000001020300000000000000000009011011000000000000051b62000000\
    090111000000000000000586616a706e09011101000000000000058031656e67090112000000000000000590\
    7a686f000901120100000000000005907a686f0009011202000000000000069201656e670000000048000500\
    010000019bfcc0ffff000000000001000001a64978ffff0000000000010001019bfcc0ffff00000000000100\
    02019f6ba8ffff000000000001000201a9b860ffff00000000
    """)

    @Test func readsWhatTheTitleIsMadeOf() throws {
        for data in [Self.sample, Self.multiAngle] {
            let streams = try #require(BlurayPlaylist(data: data, name: "00800")).streams
            #expect(streams.video == .init(codec: "H.264", format: "1080p"))
            #expect(streams.audio == [
                .init(pid: 0x1100, codec: "DTS-HD MA", channels: nil, language: "jpn"),
                .init(pid: 0x1101, codec: "PCM", channels: "2.0", language: "eng"),
            ])
            // The last is a text subtitle, which states a character set before its language.
            #expect(streams.subtitles == [
                .init(pid: 0x1200, language: "zho"), .init(pid: 0x1201, language: "zho"), .init(pid: 0x1202, language: "eng"),
            ])
        }
    }

    @Test func refusesWhatIsNotAPlaylist() {
        #expect(BlurayPlaylist(data: Data("not a playlist".utf8), name: "x") == nil)
        #expect(BlurayPlaylist(data: Self.sample.prefix(80), name: "x") == nil)
        #expect(BlurayPlaylist(data: Data(), name: "x") == nil)
    }

    @Test func readsFromASliceOfALargerBuffer() throws {
        let padded = Data([1, 2, 3]) + Self.sample
        #expect(BlurayPlaylist(data: padded.dropFirst(3), name: "00800")?.items.count == 3)
    }
}

struct BlurayDiscTests {
    private func playlist(_ name: String, _ clips: [(String, Double)]) -> BlurayPlaylist {
        BlurayPlaylist(name: name, items: clips.map { .init(clip: $0.0, start: 600, end: 600 + $0.1) }, chapters: [])
    }

    @Test func offersTitlesLongestFirstWithoutShortDecoyAndDuplicate() {
        let film = playlist("00800", [("00001", 3000), ("00002", 3000)])
        let titles = BlurayDisc.titles(from: [
            playlist("00010", [("00009", 40)]),                                              // a logo
            playlist("00020", [("00005", 1200)]),                                            // an extra
            film,
            playlist("00801", [("00001", 3000), ("00002", 3000)]),                           // the same again
            playlist("00900", [("00001", 3000), ("00001", 3000), ("00001", 3000)]),          // a decoy
        ])
        #expect(titles.map(\.playlist.name) == ["00800", "00020"])
    }

    @Test func recognizesADiscByItsFolder() {
        let folder = URL(filePath: "/disc")
        func item(_ name: String, _ kind: BrowserItem.Kind) -> BrowserItem {
            BrowserItem(url: folder.appending(component: name), kind: kind, name: name, size: nil, modified: nil)
        }
        #expect(BlurayDisc.isDisc([item("CERTIFICATE", .folder), item("bdmv", .folder)]))
        #expect(!BlurayDisc.isDisc([item("BDMV", .file), item("Films", .folder)]))
    }

    @Test func findsTheDiscsOwnName() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?><disclib><di:discinfo xmlns:di="urn:BDA:bdmv;discinfo">
        <di:title><di:name> When Marnie Was There </di:name><di:numSets>1</di:numSets></di:title>
        </di:discinfo></disclib>
        """
        #expect(BlurayDisc.name(inMetadata: Data(xml.utf8)) == "When Marnie Was There")
        #expect(BlurayDisc.name(inMetadata: Data("<disclib/>".utf8)) == nil)
    }

    @Test func writesAnEDLWithLengthPrefixedNames() {
        let edl = BlurayDisc.edl([("yoru-smb://id/a,b;c/00001.m2ts", 600, 30), ("/x/00002.m2ts", 605.5, 40)])
        #expect(edl == "edl://!no_chapters;%30%yoru-smb://id/a,b;c/00001.m2ts,600.000000,30.000000;%13%/x/00002.m2ts,605.500000,40.000000")
    }
}

struct BlurayIndexTests {
    /// Three titles: movie objects 2 and 3, and one run by Java.
    private static let index = Data(hex: """
    494e4458303230300000004e0000000000000000000000000000000000000000000000000000000000000022\
    000000000000000000000000000000000000000000000000000000000000000000000000003e400000000000\
    0000000000004000000000000001000000000003400000000000000200000000400000000000000300000000\
    800000000000303030303000
    """)

    /// Six objects. 2 sets a register and plays playlist 800; 3 jumps to 4, which plays 20;
    /// 5 plays whatever a register holds.
    private static let movieObjects = Data(hex: """
    4d4f424a3032303000000000000000000000000000000000000000000000000000000000000000000000007e\
    0000000000068000000102800000000000010000000080000001018100000000000000000000800000021080\
    0000000000050000000002800000000003200000000080000002108000000000000500000000018100000000\
    0004000000008000000102800000000000140000000080000001020000000000000300000000
    """)

    @Test func followsEachTitleToItsPlaylist() {
        let playlists = BlurayIndex.playlists(index: Self.index, movieObjects: Self.movieObjects)
        // Title 1 plays directly, title 2 through another object, title 3 cannot be read.
        #expect(playlists == [1: "00800", 2: "00020"])
    }

    @Test func survivesBrokenFiles() {
        #expect(BlurayIndex.playlists(index: Data("INDX".utf8), movieObjects: Self.movieObjects).isEmpty)
        #expect(BlurayIndex.playlists(index: Self.index, movieObjects: Self.movieObjects.prefix(60)).isEmpty)
        #expect(BlurayIndex.playlists(index: Data(), movieObjects: Data()).isEmpty)
    }
}

struct BlurayTitleTests {
    private func title(_ name: String, minutes: Double, discNumber: Int? = nil) -> BlurayDisc.Title {
        var title = BlurayDisc.Title(playlist: BlurayPlaylist(
            name: name, items: [.init(clip: name, start: 600, end: 600 + minutes * 60)], chapters: []
        ))
        title.discNumber = discNumber
        return title
    }

    @Test func aFilmIsTheOneFeatureAndTheRestExtras() {
        let titles = BlurayDisc.arranged([title("00020", minutes: 12), title("00800", minutes: 100), title("00010", minutes: 3)])
        #expect(titles.map(\.playlist.name) == ["00800", "00010", "00020"])
        #expect(titles.map(\.role) == [.feature, .extra, .extra])
        #expect(titles.map(\.number) == [1, 1, 2])
    }

    @Test func episodesAreFeaturesInTheDiscsOrder() {
        // Playlist names out of order; the disc numbers them 1 to 3.
        let titles = BlurayDisc.arranged([
            title("00007", minutes: 24, discNumber: 2), title("00009", minutes: 25, discNumber: 1),
            title("00003", minutes: 23, discNumber: 3), title("00050", minutes: 2),
        ])
        #expect(titles.map(\.playlist.name) == ["00009", "00007", "00003", "00050"])
        #expect(titles.map(\.role) == [.feature, .feature, .feature, .extra])
        #expect(titles.map(\.number) == [1, 2, 3, 1])
    }

    @Test func nothingLongEnoughMeansNoFeature() {
        #expect(BlurayDisc.arranged([title("00001", minutes: 4), title("00002", minutes: 3)]).map(\.role) == [.extra, .extra])
    }

    @Test func readsTheNamesADiscGivesItsTitles() {
        let xml = """
        <di:tableOfContents><di:titleName titleNumber="1">本編</di:titleName>
        <di:titleName titleNumber="2"> 特典映像 </di:titleName><di:titleName titleNumber="3"></di:titleName></di:tableOfContents>
        """
        #expect(BlurayDisc.titleNames(inMetadata: Data(xml.utf8)) == [1: "本編", 2: "特典映像"])
    }
}

private extension Data {
    init(hex: String) {
        let digits = Array(hex.filter(\.isHexDigit))
        self.init(stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! })
    }
}

struct BluraySubtitleTests {
    @Test func aDiscsSubtitlesAreThoseNamedAfterItsFolderAndGoToFeatures() {
        let folder = URL(filePath: "/library/Marnie (2014)")
        func item(_ name: String, _ kind: BrowserItem.Kind = .file) -> BrowserItem {
            BrowserItem(url: folder.appending(component: name), kind: kind, name: name, size: nil, modified: nil)
        }
        func title(_ name: String, minutes: Double) -> BlurayDisc.Title {
            BlurayDisc.Title(playlist: BlurayPlaylist(
                name: name, items: [.init(clip: name, start: 600, end: 600 + minutes * 60)], chapters: []
            ))
        }
        let titles = BlurayDisc.arranged([title("00800", minutes: 100), title("00010", minutes: 3)])
        let disc = BlurayDisc(folder: folder, titles: titles)
        let items = [
            item("BDMV", .folder), item("marnie (2014).chs.ass"), item("Marnie (2014).srt"),
            item("other.ass"), item("Marnie (2014).jpg"), item("Marnie (2014).ass", .folder),
        ]
        #expect(disc.subtitles(for: titles[0], among: items).map(\.name) == ["marnie (2014).chs.ass", "Marnie (2014).srt"])
        #expect(disc.subtitles(for: titles[1], among: items).isEmpty)
    }
}
