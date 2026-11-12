import SwiftUI

/// What a file is, judged by its extension: enough to tell items apart in a listing and to
/// keep unplayable ones from being opened, without reading the file.
enum MediaKind {
    case video
    case audio
    case image
    /// Loaded alongside a video, not played on its own.
    case subtitle
    case unsupported

    init(pathExtension: String) {
        let fileExtension = pathExtension.lowercased()
        if Self.videoExtensions.contains(fileExtension) {
            self = .video
        } else if Self.audioExtensions.contains(fileExtension) {
            self = .audio
        } else if Self.subtitleExtensions.contains(fileExtension) {
            self = .subtitle
        } else if Self.imageExtensions.contains(fileExtension) {
            self = .image
        } else {
            self = .unsupported
        }
    }

    var isPlayable: Bool {
        switch self {
        case .video, .audio, .image: true
        case .subtitle, .unsupported: false
        }
    }

    /// The symbol standing in for a thumbnail.
    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "music.note"
        case .image: "photo"
        case .subtitle: "captions.bubble"
        case .unsupported: "questionmark.folder"
        }
    }

    var tint: Color {
        switch self {
        case .video: Theme.accent
        case .audio: Color(red: 0.55, green: 0.72, blue: 0.98)
        case .image: Color(red: 0.60, green: 0.86, blue: 0.70)
        case .subtitle: .white.opacity(0.55)
        case .unsupported: .white.opacity(0.25)
        }
    }

    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "sup", "smi", "idx", "lrc"]

    private static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "mov", "avi", "wmv", "asf", "flv", "f4v", "webm", "ts", "m2ts", "mts", "mpg",
        "mpeg", "mpe", "m2v", "vob", "rm", "rmvb", "3gp", "3g2", "ogv", "ogm", "divx", "mxf", "dv", "y4m",
        "264", "h264", "265", "h265", "hevc", "av1", "ivf", "nut", "wtv", "m3u8",
    ]
    private static let audioExtensions: Set<String> = [
        "mp3", "flac", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "wv", "ape", "tta", "tak", "wma",
        "aiff", "aif", "alac", "ac3", "eac3", "dts", "dtshd", "thd", "truehd", "mka", "dsf", "dff", "mpc",
        "amr", "caf", "mid", "midi", "spx", "ra",
    ]
    // Only what this FFmpeg build can decode. It has the JPEG decoder and no other image
    // format (no PNG, GIF, WebP, HEIC), so those could be neither shown nor thumbnailed.
    private static let imageExtensions: Set<String> = ["jpg", "jpeg"]
}
