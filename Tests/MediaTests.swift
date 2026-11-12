import Foundation
import Testing
@testable import Yoru

struct MediaKindTests {
    @Test func classifiesByExtensionIgnoringCase() {
        #expect(MediaKind(pathExtension: "MKV") == .video)
        #expect(MediaKind(pathExtension: "flac") == .audio)
        #expect(MediaKind(pathExtension: "ass") == .subtitle)
        #expect(MediaKind(pathExtension: "jpg") == .image)
        #expect(MediaKind(pathExtension: "nfo") == .unsupported)
        #expect(MediaKind(pathExtension: "") == .unsupported)
    }

    // Images are limited to what the fork's FFmpeg build decodes.
    @Test func imagesFollowTheDecodersInTheBuild() {
        for supported in ["jpeg", "png", "webp", "gif", "bmp", "tiff"] {
            #expect(MediaKind(pathExtension: supported) == .image)
        }
        for missing in ["heic", "jxl", "avif"] {
            #expect(MediaKind(pathExtension: missing) == .unsupported)
        }
    }

    @Test func subtitlesAndUnknownFilesDoNotOpen() {
        #expect(MediaKind.video.isPlayable)
        #expect(MediaKind.audio.isPlayable)
        #expect(MediaKind.image.isPlayable)
        #expect(!MediaKind.subtitle.isPlayable)
        #expect(!MediaKind.unsupported.isPlayable)
    }
}

struct MediaInfoTests {
    @Test func namesResolutionsByTheirClass() {
        func label(_ width: Int, _ height: Int) -> String? {
            MediaInfo(duration: nil, width: width, height: height).resolutionLabel
        }
        #expect(label(3840, 2160) == "4K")
        #expect(label(3840, 1600) == "4K")
        #expect(label(1920, 1080) == "1080p")
        #expect(label(1920, 800) == "1080p")
        #expect(label(1080, 1920) == "1080p")
        #expect(label(1280, 720) == "720p")
        #expect(label(720, 480) == "480p")
        #expect(MediaInfo().resolutionLabel == nil)
    }
}

struct SubtitleChooserTests {
    private typealias Candidate = SubtitleChooser.Candidate
    private let stem = "Movie - S01E01"
    private let chinese = ["chi", "zh", "zho", "chs", "sc", "cht", "tc", "eng", "en"]

    private func tracks(selected: Int? = nil) -> [Candidate] {
        [
            Candidate(id: 1, isSelected: selected == 1, language: "en", externalName: nil),
            Candidate(id: 2, isSelected: selected == 2, language: nil, externalName: "Movie - S01E01.chs.ass"),
            Candidate(id: 3, isSelected: selected == 3, language: nil, externalName: "Movie - S01E01.chs.withDanmu.ass"),
            Candidate(id: 4, isSelected: selected == 4, language: nil, externalName: "Movie - S01E01.danmu.ass"),
        ]
    }

    @Test func picksThePlainestExternalInThePreferredLanguage() {
        #expect(SubtitleChooser.choice(among: tracks(), codes: chinese, stem: stem) == 2)
        #expect(SubtitleChooser.choice(among: tracks(selected: 1), codes: chinese, stem: stem) == 2)
    }

    @Test func keepsAnEmbeddedTrackThatRanksHigher() {
        #expect(SubtitleChooser.choice(among: tracks(selected: 1), codes: ["eng", "en"], stem: stem) == nil)
    }

    @Test func leavesThingsAloneWhenNothingMatches() {
        #expect(SubtitleChooser.choice(among: tracks(selected: 1), codes: ["jpn", "ja"], stem: stem) == nil)
    }

    @Test func withoutAPreferenceOnlyFillsAnEmptySelection() {
        #expect(SubtitleChooser.choice(among: tracks(), codes: [], stem: stem) == 2)
        #expect(SubtitleChooser.choice(among: tracks(selected: 1), codes: [], stem: stem) == nil)
    }

    @Test func readsCompoundLanguageTags() {
        let candidates = [Candidate(id: 5, isSelected: false, language: nil, externalName: "Movie - S01E01.zh-CN.srt")]
        #expect(SubtitleChooser.choice(among: candidates, codes: chinese, stem: stem) == 5)
    }

    @Test func hasNothingToDoWithoutExternalSubtitles() {
        let embedded = [Candidate(id: 1, isSelected: false, language: "chi", externalName: nil)]
        #expect(SubtitleChooser.choice(among: embedded, codes: chinese, stem: stem) == nil)
    }
}

struct HDRToneMapTests {
    private func convert(_ code: UInt8) -> UInt8 {
        var pixel: [UInt8] = [code, code, code, 0]
        pixel.withUnsafeMutableBytes {
            HDRToneMap.convertPQToSRGB($0.baseAddress!, pixelCount: 1, isBT2020: false)
        }
        return pixel[0]
    }

    @Test func blackStaysBlackAndPeakReachesWhite() {
        #expect(convert(0) == 0)
        #expect(convert(255) >= 250)
    }

    @Test func brighterInNeverComesOutDarker() {
        let outputs = (0...255).map { convert(UInt8($0)) }
        #expect(zip(outputs, outputs.dropFirst()).allSatisfy { $0 <= $1 })
    }

    // 100 nits is PQ code value 130 of 255; it should land near white, not at half gray.
    @Test func referenceWhiteIsBright() {
        #expect(convert(130) > 230)
    }
}

struct TimeEntryTests {
    @Test func readsSecondsMinutesAndHours() {
        #expect(PlayerModel.time(from: "90") == 90)
        #expect(PlayerModel.time(from: "1:30") == 90)
        #expect(PlayerModel.time(from: " 1:02:03 ") == 3723)
        #expect(PlayerModel.time(from: "0:05.5") == 5.5)
    }

    @Test func rejectsWhatIsNotATime() {
        #expect(PlayerModel.time(from: "") == nil)
        #expect(PlayerModel.time(from: "abc") == nil)
        #expect(PlayerModel.time(from: "1:2:3:4") == nil)
        #expect(PlayerModel.time(from: "1::3") == nil)
        #expect(PlayerModel.time(from: "-5") == nil)
    }
}
