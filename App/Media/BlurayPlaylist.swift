import Foundation

/// One playlist of a Blu-ray disc (`BDMV/PLAYLIST/*.mpls`): the clips that make up a
/// title, in order, and its chapter marks.
///
/// A film is cut into several `.m2ts` clips on disc; the playlist says which stretches of
/// which clips to play. Times in the file count in 45 kHz ticks and are the clip's own
/// presentation timestamps, which do not start at zero.
struct BlurayPlaylist: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        /// The clip's five-digit name, without extension.
        let clip: String
        /// Where to start and stop in the clip, in its own timestamps, seconds.
        let start: Double
        let end: Double

        var duration: Double { end - start }
    }

    /// What the title is made of, as the playlist declares it. The clips themselves do not
    /// say what language a stream is in.
    struct Streams: Equatable, Sendable {
        struct Video: Equatable, Sendable {
            /// E.g. `H.264`.
            let codec: String
            /// E.g. `1080p`; nil if the playlist gives a value this does not know.
            let format: String?
        }

        struct Audio: Equatable, Sendable {
            /// The stream's packet identifier in the clips, which is how mpv's tracks are told apart.
            let pid: Int
            /// E.g. `DTS-HD MA`.
            let codec: String
            /// E.g. `2.0`; nil for more than two channels, whose count the playlist leaves out.
            let channels: String?
            /// ISO 639-2, e.g. `jpn`.
            let language: String
        }

        struct Subtitle: Equatable, Sendable {
            let pid: Int
            let language: String
        }

        var video: Video?
        var audio: [Audio] = []
        var subtitles: [Subtitle] = []
    }

    /// The playlist's file name without extension, e.g. `00800`.
    let name: String
    let items: [Item]
    /// Where chapters begin, in seconds from the start of the title.
    let chapters: [Double]
    var streams = Streams()

    var duration: Double { items.reduce(0) { $0 + $1.duration } }

    private static let ticksPerSecond = 45_000.0

    init(name: String, items: [Item], chapters: [Double]) {
        self.name = name
        self.items = items
        self.chapters = chapters
    }

    /// Parses the contents of an `.mpls` file; nil if it is not one.
    init?(data: Data, name: String) {
        var reader = BinaryReader(data)
        guard reader.text(4) == "MPLS", reader.skip(4),
              let listStart = reader.uint32(), let marksStart = reader.uint32() else { return nil }

        // PlayList: length, reserved, item count, sub path count, then the items.
        reader.offset = Int(listStart)
        guard reader.skip(6), let itemCount = reader.uint16(), reader.skip(2) else { return nil }
        var items: [Item] = []
        var streams = Streams()
        for _ in 0..<itemCount {
            // Each item states its own length, which covers what is not read here:
            // other angles and the stream table.
            guard let length = reader.uint16() else { return nil }
            let next = reader.offset + Int(length)
            guard let clip = reader.text(5), reader.text(4) == "M2TS", let flags = reader.uint16(), reader.skip(1),
                  let start = reader.uint32(), let end = reader.uint32(), end >= start else { return nil }
            // The first item's stream table stands for the title: its items share it.
            if items.isEmpty {
                var table = reader
                streams = Self.streams(&table, isMultiAngle: flags & 0x10 != 0) ?? Streams()
            }
            items.append(Item(
                clip: clip,
                start: Double(start) / Self.ticksPerSecond,
                end: Double(end) / Self.ticksPerSecond
            ))
            reader.offset = next
        }
        guard !items.isEmpty else { return nil }

        // PlayListMark: length, count, then 14 bytes a mark. Missing marks are no error.
        var chapters: [Double] = []
        reader.offset = Int(marksStart)
        if reader.skip(4), let markCount = reader.uint16() {
            for _ in 0..<markCount {
                guard reader.skip(1), let type = reader.uint8(), let itemIndex = reader.uint16(),
                      let stamp = reader.uint32(), reader.skip(6) else { break }
                // Type 1 is an entry mark, a chapter; type 2 a link point.
                guard type == 1, Int(itemIndex) < items.count else { continue }
                let before = items[..<Int(itemIndex)].reduce(0) { $0 + $1.duration }
                let within = Double(stamp) / Self.ticksPerSecond - items[Int(itemIndex)].start
                chapters.append(before + max(within, 0))
            }
        }
        self.name = name
        self.items = items
        self.chapters = chapters.sorted()
        self.streams = streams
    }

    /// Reads a play item's stream table, with `reader` just past the item's out time.
    private static func streams(_ reader: inout BinaryReader, isMultiAngle: Bool) -> Streams? {
        // User operation mask, random access flag, still mode and time.
        guard reader.skip(12) else { return nil }
        if isMultiAngle {
            // The other angles' clips, ten bytes each.
            guard let angles = reader.uint8(), reader.skip(1), reader.skip((max(Int(angles), 1) - 1) * 10) else { return nil }
        }
        // Length, reserved, then how many streams of each kind, then reserved.
        guard reader.skip(4), let videos = reader.uint8(), let audios = reader.uint8(), let subtitles = reader.uint8(),
              reader.skip(9) else { return nil }
        var streams = Streams()
        // Each stream is an entry (where it is) followed by attributes (what it is), both
        // stating their own length.
        for index in 0..<Int(videos) + Int(audios) + Int(subtitles) {
            guard let entryLength = reader.uint8() else { return nil }
            let attributes = reader.offset + Int(entryLength)
            // Type 1 is a stream of the clip itself; the others sit in sub paths, whose
            // identifiers come before the PID.
            guard let type = reader.uint8() else { return nil }
            if type == 2 { _ = reader.skip(2) } else if type == 3 || type == 4 { _ = reader.skip(1) }
            let pid = reader.uint16().map(Int.init) ?? 0
            reader.offset = attributes
            guard let length = reader.uint8() else { return nil }
            let next = reader.offset + Int(length)
            guard let coding = reader.uint8() else { return nil }
            if index < Int(videos) {
                if streams.video == nil, let format = reader.uint8() {
                    streams.video = Streams.Video(codec: videoCodecs[coding] ?? "?", format: videoFormats[format >> 4])
                }
            } else if index < Int(videos) + Int(audios) {
                if let format = reader.uint8(), let language = reader.text(3) {
                    streams.audio.append(Streams.Audio(
                        pid: pid, codec: audioCodecs[coding] ?? "?", channels: audioChannels[format >> 4], language: language
                    ))
                }
            } else {
                // A text subtitle states its character set before its language.
                if coding == 0x92 { _ = reader.skip(1) }
                if let language = reader.text(3) {
                    streams.subtitles.append(Streams.Subtitle(pid: pid, language: language))
                }
            }
            reader.offset = next
        }
        return streams
    }

    private static let videoCodecs: [UInt8: String] = [0x01: "MPEG-1", 0x02: "MPEG-2", 0x1B: "H.264", 0x24: "HEVC", 0xEA: "VC-1"]
    private static let videoFormats: [UInt8: String] = [
        1: "480i", 2: "576i", 3: "480p", 4: "1080i", 5: "720p", 6: "1080p", 7: "576p", 8: "2160p",
    ]
    private static let audioCodecs: [UInt8: String] = [
        0x03: "MPEG", 0x04: "MPEG", 0x80: "PCM", 0x81: "Dolby Digital", 0x82: "DTS", 0x83: "Dolby TrueHD",
        0x84: "Dolby Digital Plus", 0x85: "DTS-HD HR", 0x86: "DTS-HD MA", 0xA1: "Dolby Digital Plus", 0xA2: "DTS Express",
    ]
    private static let audioChannels: [UInt8: String] = [1: "1.0", 3: "2.0"]

    /// Whether the playlist replays its clips, as the decoys some discs carry do: dozens
    /// of playlists as long as the film, each shuffling the same clips.
    var repeatsClips: Bool {
        var uses: [String: Int] = [:]
        for item in items {
            uses[item.clip, default: 0] += 1
        }
        return uses.values.contains { $0 > 2 }
    }
}
