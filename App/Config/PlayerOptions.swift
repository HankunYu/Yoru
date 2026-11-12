import Foundation

/// A track language preference, mapped to the code list mpv's `slang` / `alang` expect.
enum LanguagePreference: Hashable, Identifiable {
    case automatic
    case chinese
    case english
    case japanese
    case korean
    /// A list in the file that matches none of the presets; shown as is and left untouched.
    case custom(String)

    static let presets: [LanguagePreference] = [.automatic, .chinese, .english, .japanese, .korean]

    var id: String { codes ?? "" }

    /// The option value, or nil to leave the option unset.
    var codes: String? {
        switch self {
        case .automatic: nil
        case .chinese: "chi,zh,zho,chs,sc,cht,tc"
        case .english: "eng,en"
        case .japanese: "jpn,ja"
        case .korean: "kor,ko"
        case .custom(let value): value
        }
    }

    init(codes: String?) {
        guard let codes, !codes.isEmpty else {
            self = .automatic
            return
        }
        // A list that starts with a preset's codes is that preset plus fallbacks.
        let match = Self.presets.first { preset in
            preset.codes.map { codes == $0 || codes.hasPrefix($0 + ",") } ?? false
        }
        self = match ?? .custom(codes)
    }
}

/// The mpv options surfaced in Settings, read from and written to `mpv.conf`.
///
/// `mpv.conf` stays the single source of truth: these are the same lines a user would edit
/// by hand, and an option absent from the file reads as its default here.
struct PlayerOptions: Equatable {
    var subtitleLanguage = LanguagePreference.automatic
    var audioLanguage = LanguagePreference.automatic
    var subtitleScale = 1.0
    var loadsExternalSubtitles = true
    var usesHardwareDecoding = true
    var usesHighQualityScaling = false
    var resumesPlayback = true
    /// `sub-font`; nil for the bundled default.
    var subtitleFont: String?
    /// `sub-pos`: 100 is the bottom of the picture, lower values move subtitles up.
    var subtitlePosition = 100
    /// HDR video goes to the display as HDR; off converts it to SDR.
    var outputsHDR = true
    var debands = false
    /// Leave the player when a video ends, instead of pausing on its last frame.
    var closesAtEnd = false
    /// `demuxer-max-bytes` in MiB; nil for mpv's default.
    var readAheadMegabytes: Int?

    static let fileURL = ConfigDirectory.url.appending(path: "mpv.conf")

    static func load() -> PlayerOptions {
        let file = KeyValueFile(url: fileURL)
        var options = PlayerOptions()
        options.subtitleLanguage = LanguagePreference(codes: file.value(for: "slang"))
        options.audioLanguage = LanguagePreference(codes: file.value(for: "alang"))
        if let value = file.value(for: "sub-scale"), let scale = Double(value), scale > 0 {
            options.subtitleScale = scale
        }
        if let value = file.value(for: "sub-auto") {
            options.loadsExternalSubtitles = value != "no"
        }
        if let value = file.value(for: "hwdec") {
            options.usesHardwareDecoding = value != "no"
        }
        options.usesHighQualityScaling = file.value(for: "profile") == "high-quality"
        if let value = file.value(for: "save-position-on-quit") {
            options.resumesPlayback = value != "no"
        }
        options.subtitleFont = file.value(for: "sub-font")
        if let value = file.value(for: "sub-pos"), let position = Double(value) {
            options.subtitlePosition = Int(position.rounded())
        }
        options.outputsHDR = file.value(for: "target-colorspace-hint") != "no"
        options.debands = file.value(for: "deband") == "yes"
        options.closesAtEnd = file.value(for: "keep-open") == "no"
        if let value = file.value(for: "demuxer-max-bytes"), value.hasSuffix("MiB") {
            options.readAheadMegabytes = Int(value.dropLast(3))
        }
        return options
    }

    /// Writes only the options that differ from `previous`, so untouched lines (including
    /// values this type cannot represent, like a hand-written `hwdec=auto-safe`) stay as
    /// the user wrote them.
    func save(changedFrom previous: PlayerOptions) {
        var file = KeyValueFile(url: Self.fileURL)
        if subtitleLanguage != previous.subtitleLanguage {
            file.set("slang", to: subtitleLanguage.codes)
        }
        if audioLanguage != previous.audioLanguage {
            file.set("alang", to: audioLanguage.codes)
        }
        if subtitleScale != previous.subtitleScale {
            file.set("sub-scale", to: String(format: "%.2g", subtitleScale))
        }
        if loadsExternalSubtitles != previous.loadsExternalSubtitles {
            file.set("sub-auto", to: loadsExternalSubtitles ? "fuzzy" : "no")
        }
        if usesHardwareDecoding != previous.usesHardwareDecoding {
            file.set("hwdec", to: usesHardwareDecoding ? "videotoolbox" : "no")
        }
        if usesHighQualityScaling != previous.usesHighQualityScaling {
            file.set("profile", to: usesHighQualityScaling ? "high-quality" : nil)
        }
        if resumesPlayback != previous.resumesPlayback {
            file.set("save-position-on-quit", to: resumesPlayback ? "yes" : "no")
        }
        if subtitleFont != previous.subtitleFont {
            file.set("sub-font", to: subtitleFont.map { "\"\($0)\"" })
        }
        if subtitlePosition != previous.subtitlePosition {
            file.set("sub-pos", to: subtitlePosition == 100 ? nil : String(subtitlePosition))
        }
        // For the three below the app's own default is the "on" state, so that state is
        // expressed by leaving the line out.
        if outputsHDR != previous.outputsHDR {
            file.set("target-colorspace-hint", to: outputsHDR ? nil : "no")
        }
        if debands != previous.debands {
            file.set("deband", to: debands ? "yes" : nil)
        }
        if closesAtEnd != previous.closesAtEnd {
            file.set("keep-open", to: closesAtEnd ? "no" : nil)
        }
        if readAheadMegabytes != previous.readAheadMegabytes {
            file.set("demuxer-max-bytes", to: readAheadMegabytes.map { "\($0)MiB" })
        }
        file.save()
    }
}
