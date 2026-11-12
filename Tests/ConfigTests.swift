import Foundation
import Testing
@testable import Yoru

/// A scratch file that removes itself.
private final class ScratchFile {
    let url = URL.temporaryDirectory.appending(path: "yoru-test-\(UUID().uuidString).conf")

    init(_ contents: String) {
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var contents: String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

struct KeyValueFileTests {
    @Test func readsValuesBareFlagsAndQuotes() {
        let scratch = ScratchFile("""
        # comment
        hwdec=videotoolbox
        sub-font="Noto Sans CJK SC"
        deband
        no-keep-open
        """)
        let file = KeyValueFile(url: scratch.url)
        #expect(file.value(for: "hwdec") == "videotoolbox")
        #expect(file.value(for: "sub-font") == "Noto Sans CJK SC")
        #expect(file.value(for: "deband") == "yes")
        #expect(file.value(for: "keep-open") == "no")
        #expect(file.value(for: "missing") == nil)
    }

    @Test func laterLinesWin() {
        // Held in a constant: a temporary would delete its file before it is read.
        let scratch = ScratchFile("sub-scale=1\nsub-scale=1.5\n")
        let file = KeyValueFile(url: scratch.url)
        #expect(file.value(for: "sub-scale") == "1.5")
    }

    @Test func ignoresOptionsInsideProfiles() {
        let scratch = ScratchFile("hwdec=no\n\n[fast]\nhwdec=videotoolbox\ndeband=no\n")
        let file = KeyValueFile(url: scratch.url)
        #expect(file.value(for: "hwdec") == "no")
        #expect(file.value(for: "deband") == nil)
    }

    @Test func setReplacesInPlaceAndKeepsEverythingElse() {
        let scratch = ScratchFile("# mine\nslang=eng\nhwdec=no\n\n[fast]\nhwdec=auto\n")
        var file = KeyValueFile(url: scratch.url)
        file.set("hwdec", to: "videotoolbox")
        file.save()
        #expect(scratch.contents == "# mine\nslang=eng\nhwdec=videotoolbox\n\n[fast]\nhwdec=auto\n")
    }

    @Test func setAddsAboveTheFirstProfile() {
        let scratch = ScratchFile("slang=eng\n\n[fast]\nhwdec=auto\n")
        var file = KeyValueFile(url: scratch.url)
        file.set("deband", to: "yes")
        file.save()
        #expect(scratch.contents == "slang=eng\ndeband=yes\n\n[fast]\nhwdec=auto\n")
    }

    @Test func setNilRemovesEveryTopLevelOccurrence() {
        let scratch = ScratchFile("deband=yes\nslang=eng\ndeband=no\n")
        var file = KeyValueFile(url: scratch.url)
        file.set("deband", to: nil)
        file.save()
        #expect(scratch.contents == "slang=eng\n")
    }

    @Test func setCollapsesDuplicatesIntoTheLastOne() {
        let scratch = ScratchFile("deband=yes\nslang=eng\ndeband=no\n")
        var file = KeyValueFile(url: scratch.url)
        file.set("deband", to: "yes")
        file.save()
        #expect(scratch.contents == "slang=eng\ndeband=yes\n")
    }
}

struct LanguagePreferenceTests {
    @Test func recognizesPresetsWithFallbacks() {
        #expect(LanguagePreference(codes: nil) == .automatic)
        #expect(LanguagePreference(codes: "") == .automatic)
        #expect(LanguagePreference(codes: "jpn,ja") == .japanese)
        #expect(LanguagePreference(codes: "chi,zh,zho,chs,sc,cht,tc,eng,en") == .chinese)
        #expect(LanguagePreference(codes: "fra,fr") == .custom("fra,fr"))
    }
}

struct TouchBindingsTests {
    @Test func defaultsPauseOnEveryThird() {
        let section = TouchBindings.section(for: YoruOptions())
        #expect(section.contains("GESTURE_DOUBLE_TAP_LEFT cycle pause"))
        #expect(section.contains("GESTURE_DOUBLE_TAP_RIGHT cycle pause"))
        #expect(section.contains("GESTURE_LEFT_UP script-message yoru brightness 0.03"))
        #expect(section.contains("GESTURE_RIGHT_UP script-message yoru volume 0.03"))
        #expect(section.contains("GESTURE_HOLD script-message yoru hold-speed 2"))
    }

    @Test func optionsReshapeTheBindings() {
        var options = YoruOptions()
        options.doubleTapSeek = 10
        options.swapsGestureSides = true
        options.volumeGesture = false
        options.holdSpeed = 2.5
        let section = TouchBindings.section(for: options)
        #expect(section.contains("GESTURE_DOUBLE_TAP_LEFT no-osd seek -10;"))
        #expect(section.contains("GESTURE_DOUBLE_TAP_RIGHT no-osd seek 10;"))
        #expect(section.contains("GESTURE_DOUBLE_TAP_CENTER cycle pause"))
        #expect(section.contains("GESTURE_RIGHT_UP script-message yoru brightness 0.03"))
        #expect(section.contains("GESTURE_LEFT_UP ignore"))
        #expect(section.contains("hold-speed 2.5"))
    }
}
