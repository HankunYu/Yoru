import CoreGraphics
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
        #expect(label(7680, 4320) == "8K")
        #expect(label(4320, 7680) == "8K")
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

struct PreviewCacheTests {
    private func file(_ key: String, _ size: Int64, day: Double) -> MediaPreviewStore.CachedFile {
        MediaPreviewStore.CachedFile(key: key, size: size, lastUse: Date(timeIntervalSince1970: day * 86_400))
    }

    @Test func keepsEverythingUnderTheLimit() {
        let files = [file("a", 40, day: 1), file("b", 60, day: 2)]
        #expect(MediaPreviewStore.keysToEvict(from: files, limit: 100).isEmpty)
    }

    @Test func evictsTheLeastRecentlyUsedDownToAMargin() {
        // Each entry is a thumbnail and its facts; the newer of the two dates counts.
        let files = [
            file("old", 30, day: 1), file("old", 2, day: 1),
            file("shown", 30, day: 1), file("shown", 2, day: 9),
            file("mid", 30, day: 5), file("mid", 2, day: 5),
            file("new", 30, day: 8), file("new", 2, day: 8),
        ]
        // 128 over a limit of 100: down to at most 80, so the two oldest go.
        #expect(MediaPreviewStore.keysToEvict(from: files, limit: 100) == ["old", "mid"])
    }
}

struct ThumbnailDecodingTests {
    @Test func decodesUpTo4KInSoftware() {
        #expect(ThumbnailRenderer.decodingPlan(width: 3840, height: 2160, codec: "av1") == .software)
        #expect(ThumbnailRenderer.decodingPlan(width: 4096, height: 2160, codec: "hevc") == .software)
        #expect(ThumbnailRenderer.decodingPlan(width: nil, height: nil, codec: "hevc") == .software)
    }

    @Test func leavesLargerVideoToTheHardwareOrSkipsIt() {
        #expect(ThumbnailRenderer.decodingPlan(width: 7680, height: 4320, codec: "hevc") == .hardwareOnly)
        #expect(ThumbnailRenderer.decodingPlan(width: 4320, height: 7680, codec: "h264") == .hardwareOnly)
        #expect(ThumbnailRenderer.decodingPlan(width: 8192, height: 4096, codec: "av1") == .skip)
    }

    @Test func largePhotosAreASingleFrame() {
        #expect(ThumbnailRenderer.decodingPlan(width: 12000, height: 9000, codec: "mjpeg") == .software)
    }

    @Test func turnsFramesClockwise() throws {
        // Two pixels side by side: red on the left, blue on the right.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        let context = try #require(CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())

        /// The pixels in reading order, as "R" or "B".
        func pixels(_ image: CGImage) -> [String] {
            let data = image.dataProvider!.data! as Data
            return (0..<image.height).flatMap { row in
                (0..<image.width).map { column in
                    // BGRX in memory.
                    data[row * image.bytesPerRow + column * 4 + 2] > 127 ? "R" : "B"
                }
            }
        }
        #expect(pixels(image) == ["R", "B"])
        let quarter = ThumbnailRenderer.rotated(image, clockwise: 90)
        #expect((quarter.width, quarter.height) == (1, 2))
        // Turned clockwise, the left end comes out on top.
        #expect(pixels(quarter) == ["R", "B"])
        #expect(pixels(ThumbnailRenderer.rotated(image, clockwise: 180)) == ["B", "R"])
        #expect(pixels(ThumbnailRenderer.rotated(image, clockwise: 270)) == ["B", "R"])
        #expect(ThumbnailRenderer.rotated(image, clockwise: 0) === image)
    }
}

struct PlaybackMemoryTests {
    /// The limit measured on an iPhone: about 3.4 GB.
    private let limit: Int64 = 3_375 << 20

    @Test func admitsWhatPlayedOnThePhone() {
        #expect(PlaybackMemory.fits(width: 4096, height: 4096, pixelFormat: "yuv420p", limit: limit))
        #expect(PlaybackMemory.fits(width: 5760, height: 5760, pixelFormat: "yuv420p", limit: limit))
        #expect(PlaybackMemory.fits(width: 8192, height: 4608, pixelFormat: "yuv420p", limit: limit))
        #expect(PlaybackMemory.fits(width: 3840, height: 2160, pixelFormat: "yuv420p10", limit: limit))
    }

    @Test func declinesWhatTheSystemEndedTheAppFor() {
        #expect(!PlaybackMemory.fits(width: 8192, height: 8192, pixelFormat: "yuv420p", limit: limit))
        #expect(!PlaybackMemory.fits(width: 8192, height: 8192, pixelFormat: nil, limit: limit))
    }

    @Test func deepFormatsCountTwice() {
        let plain = PlaybackMemory.bytesNeeded(width: 1920, height: 1080, pixelFormat: "yuv420p")
        #expect(PlaybackMemory.bytesNeeded(width: 1920, height: 1080, pixelFormat: "yuv420p10") == plain * 2)
        #expect(plain == 1920 * 1080 * 3 / 2 * 36)
    }

    @Test func aLargerDeviceTakesLargerVideo() {
        #expect(PlaybackMemory.fits(width: 8192, height: 8192, pixelFormat: "yuv420p", limit: 6 << 30))
    }
}
