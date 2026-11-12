import UIKit

/// Facts about a media file, read once while its thumbnail is generated and cached with it.
struct MediaInfo: Codable, Sendable, Equatable {
    var duration: Double?
    var width: Int?
    var height: Int?
    var isHDR = false

    /// A short resolution name such as `1080p` or `4K`, by the frame's larger class.
    var resolutionLabel: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let long = max(width, height)
        let short = min(width, height)
        if long >= 3800 || short >= 2100 { return "4K" }
        if long >= 2500 || short >= 1400 { return "1440p" }
        if long >= 1900 || short >= 1000 { return "1080p" }
        if long >= 1200 || short >= 700 { return "720p" }
        return "\(short)p"
    }

    var durationLabel: String? {
        guard let duration, duration >= 1 else { return nil }
        return Duration.seconds(duration.rounded())
            .formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// What the browser shows for a file: a frame from it (nil when it has no picture) and its facts.
struct MediaPreview: Sendable {
    let image: UIImage?
    let info: MediaInfo
}
