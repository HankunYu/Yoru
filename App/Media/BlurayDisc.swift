import Foundation

/// A Blu-ray disc as a folder: the titles its playlists describe, and how to play one.
///
/// mpv's own `bd://` reads from a local path only. Here the playlists are read through
/// whatever source holds the folder, and a title is handed to mpv as an EDL of its clips,
/// so a disc on a server plays like one on the device. There are no menus, and a disc
/// still under its copy protection does not play.
struct BlurayDisc: Sendable {
    struct Title: Identifiable, Equatable, Sendable {
        /// What a title is to the disc, judged by its length.
        enum Role: Equatable, Sendable {
            /// The film, or one of several of about its length: episodes, or cuts.
            case feature
            case extra
        }

        let playlist: BlurayPlaylist
        var role = Role.extra
        /// The title's place among those of its role, from 1.
        var number = 1
        /// The name the disc itself gives the title, on the discs that name them.
        var name: String?
        /// The disc's own number for the title, if it could be worked out.
        var discNumber: Int?
        var id: String { playlist.name }
    }

    /// A feature is at least this long ...
    static let shortestFeature = 600.0
    /// ... and at least this much of the longest title.
    static let featureShare = 0.6

    /// The folder that holds `BDMV`.
    let folder: URL
    /// Longest first.
    let titles: [Title]
    /// The disc's name as its own metadata gives it, on the discs that carry any.
    var metadataName: String?

    /// Titles shorter than this are menu loops and logos.
    static let shortestTitle = 60.0
    /// Playlists read at most; discs with decoys carry hundreds.
    static let playlistLimit = 200

    /// Whether a folder's listing shows it to be a disc.
    static func isDisc(_ items: [BrowserItem]) -> Bool {
        items.contains { $0.kind == .folder && $0.name.uppercased() == "BDMV" }
    }

    /// Reads the disc's playlists. Nil if the folder holds none that can be read.
    static func load(from folder: URL, source: any MediaSource) async -> BlurayDisc? {
        let directory = folder.appending(components: "BDMV", "PLAYLIST", directoryHint: .isDirectory)
        guard let listing = try? await source.contents(of: directory) else { return nil }
        let files = listing
            .filter { $0.kind == .file && $0.url.pathExtension.lowercased() == "mpls" }
            .sorted { $0.name < $1.name }
            .prefix(playlistLimit)
        var playlists: [BlurayPlaylist] = []
        for file in files {
            guard !Task.isCancelled else { return nil }
            guard let data = try? await source.data(of: file.url),
                  let playlist = BlurayPlaylist(data: data, name: file.title) else { continue }
            playlists.append(playlist)
        }
        var titles = Self.titles(from: playlists)
        guard !titles.isEmpty else { return nil }
        // The disc's numbering of its titles, and the names it may give them by number.
        let bdmv = folder.appending(component: "BDMV", directoryHint: .isDirectory)
        var numbers: [String: Int] = [:]
        if let index = try? await source.data(of: bdmv.appending(component: "index.bdmv")),
           let objects = try? await source.data(of: bdmv.appending(component: "MovieObject.bdmv")) {
            // A playlist reached from several titles goes by the lowest.
            for (number, playlist) in BlurayIndex.playlists(index: index, movieObjects: objects).sorted(by: { $0.key > $1.key }) {
                numbers[playlist] = number
            }
        }
        let metadata = await metadata(in: folder, source: source)
        let names = metadata.map(titleNames(inMetadata:)) ?? [:]
        for index in titles.indices {
            let number = numbers[titles[index].playlist.name]
            titles[index].discNumber = number
            titles[index].name = number.flatMap { names[$0] }
        }
        var disc = BlurayDisc(folder: folder, titles: arranged(titles))
        disc.metadataName = metadata.flatMap(name(inMetadata:))
        return disc
    }

    /// Sorts titles into features and extras, each in the disc's order, and numbers them.
    ///
    /// The disc's own numbers decide the order where they are known, which keeps episodes
    /// in sequence; playlists' names stand in where they are not.
    static func arranged(_ titles: [Title]) -> [Title] {
        let longest = titles.map(\.playlist.duration).max() ?? 0
        var features: [Title] = []
        var extras: [Title] = []
        for var title in titles {
            let duration = title.playlist.duration
            if duration >= shortestFeature, duration >= longest * featureShare {
                title.role = .feature
                features.append(title)
            } else {
                title.role = .extra
                extras.append(title)
            }
        }
        func inDiscOrder(_ titles: [Title]) -> [Title] {
            let sorted = titles.sorted {
                ($0.discNumber ?? .max, $0.playlist.name) < ($1.discNumber ?? .max, $1.playlist.name)
            }
            return sorted.enumerated().map { index, title in
                var title = title
                title.number = index + 1
                return title
            }
        }
        // A lone feature is the film; nothing else is as long. With none, all are extras.
        return inDiscOrder(features) + inDiscOrder(extras)
    }

    var featureCount: Int { titles.count { $0.role == .feature } }

    /// The contents of `BDMV/META/DL/bdmt_<language>.xml`, preferring the device's language.
    private static func metadata(in folder: URL, source: any MediaSource) async -> Data? {
        let directory = folder.appending(components: "BDMV", "META", "DL", directoryHint: .isDirectory)
        guard let listing = try? await source.contents(of: directory) else { return nil }
        let files = listing.filter { $0.kind == .file && $0.name.lowercased().hasPrefix("bdmt_") && $0.name.lowercased().hasSuffix(".xml") }
        let preferred = Locale.current.language.languageCode?.identifier(.alpha3) ?? "eng"
        // Chinese goes by either of its two codes.
        let wanted = preferred == "zho" ? ["zho", "chi"] : [preferred]
        let file = files.first { file in wanted.contains { file.name.lowercased().contains("_" + $0) } }
            ?? files.first { $0.name.lowercased().contains("_eng") }
            ?? files.first
        guard let file else { return nil }
        return try? await source.data(of: file.url)
    }

    /// The names a disc gives its titles, by the disc's title number.
    static func titleNames(inMetadata data: Data) -> [Int: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var names: [Int: String] = [:]
        for match in text.matches(of: /<di:titleName[^>]*titleNumber="(\d+)"[^>]*>\s*([^<]+?)\s*<\/di:titleName>/) {
            if let number = Int(match.1), !match.2.isEmpty {
                names[number] = String(match.2)
            }
        }
        return names
    }

    /// The text of the first `<di:name>` element.
    static func name(inMetadata data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              let match = text.firstMatch(of: /<di:name>\s*([^<]+?)\s*<\/di:name>/) else { return nil }
        let name = String(match.1)
        return name.isEmpty ? nil : name
    }

    /// What is worth offering of a disc's playlists: without the short, the decoys and
    /// the duplicates, longest first.
    static func titles(from playlists: [BlurayPlaylist]) -> [Title] {
        var seen: [[BlurayPlaylist.Item]] = []
        var titles: [Title] = []
        for playlist in playlists.sorted(by: { ($0.duration, $1.name) > ($1.duration, $0.name) }) {
            guard playlist.duration >= shortestTitle, !playlist.repeatsClips, !seen.contains(playlist.items) else { continue }
            seen.append(playlist.items)
            titles.append(Title(playlist: playlist))
        }
        return titles
    }

    /// The disc's name: its own if it has one, else its folder's.
    var name: String { metadataName ?? folder.lastPathComponent }

    /// The subtitle files that go with the disc: those beside `BDMV` whose names begin
    /// with the disc folder's, as `Film/Film.chs.ass` for `Film/BDMV`. A disc has one set,
    /// so they are the film's: features get them, extras do not.
    func subtitles(for title: Title, among items: [BrowserItem]) -> [BrowserItem] {
        guard title.role == .feature else { return [] }
        let stem = folder.lastPathComponent.lowercased()
        return items.filter { $0.kind == .file && $0.mediaKind == .subtitle && $0.name.lowercased().hasPrefix(stem) }
    }

    /// The clip a title is pictured by: its longest, which is the least likely to be a logo.
    func coverClip(of title: Title) -> URL? {
        guard let item = title.playlist.items.max(by: { $0.duration < $1.duration }) else { return nil }
        return folder.appending(components: "BDMV", "STREAM", item.clip + ".m2ts")
    }

    /// The location mpv plays `title` from: an EDL naming each clip's stretch.
    func location(of title: Title, source: any MediaSource) -> String {
        let streams = folder.appending(components: "BDMV", "STREAM", directoryHint: .isDirectory)
        return Self.edl(title.playlist.items.map { item in
            (source.playback(of: streams.appending(component: item.clip + ".m2ts")).location, item.start, item.duration)
        })
    }

    /// An inline mpv EDL. File names are length-prefixed, so they may hold anything; the
    /// chapters come from the playlist's marks instead of one per segment.
    static func edl(_ segments: [(file: String, start: Double, length: Double)]) -> String {
        let entries = segments.map { segment in
            "%\(segment.file.utf8.count)%\(segment.file),\(format(segment.start)),\(format(segment.length))"
        }
        return "edl://!no_chapters;" + entries.joined(separator: ";")
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%.6f", seconds)
    }
}
