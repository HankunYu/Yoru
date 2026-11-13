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

struct ShaderLibraryTests {
    @Test func sortsFilesIntoShadersAndTables() {
        let library = ShaderLibrary(names: [
            "Anime4K_Upscale_CNN_x2_M.glsl", "notes.txt", ".DS_Store", "Film.cube", "anime4k_Clamp_Highlights.GLSL",
            "FSRCNNX_x2_8-0-4-1.hook", "Warm.CUBE", "Anime4K_Restore_CNN_M.glsl",
        ])
        #expect(library.shaders == [
            "anime4k_Clamp_Highlights.GLSL", "Anime4K_Restore_CNN_M.glsl", "Anime4K_Upscale_CNN_x2_M.glsl", "FSRCNNX_x2_8-0-4-1.hook",
        ])
        #expect(library.tables == ["Film.cube", "Warm.CUBE"])
        #expect(!library.isEmpty)
        #expect(ShaderLibrary(names: ["notes.txt"]).isEmpty)
    }

    @Test func keepsARememberedOrderAndDropsWhatIsGone() {
        let library = ShaderLibrary(names: ["a.glsl", "b.glsl", "c.glsl"])
        #expect(library.existing(["c.glsl", "gone.glsl", "a.glsl"]) == ["c.glsl", "a.glsl"])
    }
}

struct ShaderGroupTests {
    @Test func readsANameALine() {
        let group = ShaderLibrary.Group(file: "Mine.group", text: "# my own\na.glsl\n\n  b.glsl  \r\nc.glsl\n")
        #expect(group.shaders == ["a.glsl", "b.glsl", "c.glsl"])
        #expect(group.title == "Mine")
    }

    @Test func readsALinePastedFromInstallNotes() {
        let text = "\"~~/shaders/Anime4K_Clamp_Highlights.glsl:~~/shaders/Anime4K_Restore_CNN_M.glsl:~~/shaders/Anime4K_Upscale_CNN_x2_M.glsl\""
        #expect(ShaderLibrary.Group(file: "A.group", text: text).shaders == [
            "Anime4K_Clamp_Highlights.glsl", "Anime4K_Restore_CNN_M.glsl", "Anime4K_Upscale_CNN_x2_M.glsl",
        ])
    }

    @Test func writesWhatItReads() {
        let group = ShaderLibrary.Group(file: "A.group", shaders: ["one.glsl", "two.glsl"])
        #expect(ShaderLibrary.Group(file: "A.group", text: group.text) == group)
    }

    @Test func countsWhatIsMissing() {
        let library = ShaderLibrary(names: ["a.glsl", "c.glsl"])
        let group = ShaderLibrary.Group(file: "G.group", shaders: ["a.glsl", "b.glsl", "c.glsl", "d.glsl"])
        #expect(library.missingCount(in: group) == 2)
        #expect(library.existing(group.shaders) == ["a.glsl", "c.glsl"])
    }
}

struct ShaderSourceTests {
    private let text = """
    // CRT television
    //!HOOK OUTPUT
    #define LINES 288.0          // scanlines down the picture
    #define SCANLINE_DEPTH 0.55  // how dark the gaps get
    #define TAPS 4
    #define OFFSET -.5
    #define NAME something
    #define LINES 100.0
      #define  MASK  0.30
    vec4 hook() { return HOOKED_tex(HOOKED_pos) * SCANLINE_DEPTH; }
    """

    @Test func findsTheNumbersMeantToBeChanged() {
        let parameters = ShaderSource(text).parameters
        #expect(parameters.map(\.name) == ["LINES", "SCANLINE_DEPTH", "TAPS", "OFFSET", "MASK"])
        #expect(parameters.map(\.value) == ["288.0", "0.55", "4", "-.5", "0.30"])
        #expect(parameters[0].comment == "scanlines down the picture")
        #expect(parameters[2].comment == nil)
    }

    @Test func stepsByTheLastWrittenDigit() {
        let parameters = ShaderSource(text).parameters
        #expect(parameters.map(\.step) == [1, 0.01, 1, 0.1, 0.01])
        #expect(parameters[0].formatted(300) == "300.0")
        #expect(parameters[1].formatted(0.6) == "0.60")
        #expect(parameters[2].formatted(5.4) == "5")
    }

    @Test func rewritesOnlyTheNumber() {
        var source = ShaderSource(text)
        source.set(source.parameters[1], to: "0.70")
        #expect(source.text.contains("#define SCANLINE_DEPTH 0.70  // how dark the gaps get"))
        source.set(source.parameters[4], to: "0.10")
        #expect(source.text.contains("  #define  MASK  0.10"))
        // Nothing else moved.
        #expect(source.text.split(separator: "\n").count == text.split(separator: "\n").count)
        #expect(source.parameters.map(\.value) == ["288.0", "0.70", "4", "-.5", "0.10"])
    }
}

struct ShaderLibraryNamingTests {
    @Test func findsANameNoGroupHas() {
        var library = ShaderLibrary(names: [])
        library.groups = [.init(file: "Mine.group", shaders: []), .init(file: "mine 2.group", shaders: [])]
        #expect(library.unusedGroupName("Mine") == "Mine 3")
        #expect(library.unusedGroupName("Other") == "Other")
    }

    @Test func tellsWhichGroupsUseAShader() {
        var library = ShaderLibrary(names: ["a.glsl", "b.glsl"])
        library.groups = [.init(file: "One.group", shaders: ["a.glsl"]), .init(file: "Two.group", shaders: ["b.glsl", "a.glsl"])]
        #expect(library.groups(using: "b.glsl").map(\.title) == ["Two"])
        #expect(library.groups(using: "a.glsl").count == 2)
    }
}
