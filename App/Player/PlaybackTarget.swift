import Foundation

/// The files a playback can move through: what the browser listed when one was opened,
/// in its order. That is a folder, or the results of a search.
struct PlaybackQueue {
    /// The files of the opened one's kind (videos or audio), in order.
    let items: [BrowserItem]
    /// Everything listed, for finding each file's subtitles when the files share a folder.
    let siblings: [BrowserItem]
    /// For search results from several folders: what each folder holds, by `folderKey`.
    let listings: [String: [BrowserItem]]

    init(startingAt item: BrowserItem, among siblings: [BrowserItem], listings: [String: [BrowserItem]] = [:]) {
        let kind = item.mediaKind
        items = siblings.filter { $0.kind == .file && $0.mediaKind == kind }
        self.siblings = siblings
        self.listings = listings
    }

    /// Names a folder the same way whether its URL ends in a slash or not.
    static func folderKey(_ folder: URL) -> String {
        let text = folder.absoluteString
        return text.hasSuffix("/") ? String(text.dropLast()) : text
    }

    /// The files beside `item`, among which its subtitles are looked for.
    func siblings(of item: BrowserItem) -> [BrowserItem] {
        listings[Self.folderKey(item.url.deletingLastPathComponent())] ?? siblings
    }

    func index(of target: PlaybackTarget) -> Int? {
        items.firstIndex { $0.url == target.itemURL }
    }

    @MainActor
    func target(at index: Int) -> PlaybackTarget {
        var target = PlaybackTarget(item: items[index], siblings: siblings(of: items[index]))
        target.queue = self
        return target
    }
}

/// Something the player can open: a location string handed to mpv's `loadfile` verbatim.
struct PlaybackTarget: Identifiable {
    let id = UUID()
    /// A file path or any URL mpv understands (`smb://`, `http://`, `dav://`, ...).
    let location: String
    /// Subtitle files to load with the file. mpv finds same-folder subtitles itself only
    /// for local files; for other sources the browser supplies them.
    let externalSubtitles: [String]
    /// Whether to turn mpv's cache on explicitly; see `PlaybackLocation`.
    let forcesCache: Bool
    /// The browser item this came from, if it came from the browser.
    let itemURL: URL?
    /// Where previous and next lead; nil for a file opened on its own.
    var queue: PlaybackQueue?
    /// Set on a first viewing with subtitles supplied by the app: how to pick the one to
    /// start with, since mpv's language preference cannot see them. See `SubtitleChooser`.
    let initialSubtitleChoice: InitialSubtitleChoice?

    struct InitialSubtitleChoice {
        /// Preferred language codes, best first.
        let codes: [String]
        /// The video's file name without its extension.
        let stem: String
    }
    /// Set when the file was opened in place from another app (Files, a file provider);
    /// access must be released with `endAccess()` when playback ends.
    private let securityScopedURL: URL?

    init(location: String) {
        self.location = location
        externalSubtitles = []
        // An smb:// link is served by the app, so mpv does not see it as a network source.
        forcesCache = location.lowercased().hasPrefix(SMBSource.linkScheme + "://")
        initialSubtitleChoice = nil
        itemURL = nil
        securityScopedURL = nil
    }

    /// A file picked in the browser, with the other items of its folder.
    @MainActor
    init(item: BrowserItem, siblings: [BrowserItem]) {
        securityScopedURL = nil
        itemURL = item.url
        let source = MediaSources.source(for: item.url)
        let playback = source.playback(of: item.url)
        location = playback.location
        forcesCache = playback.forcesCache
        let options = PlayerOptions.load()
        // mpv scans the folder of a local file itself.
        guard !item.url.isFileURL, options.loadsExternalSubtitles else {
            externalSubtitles = []
            initialSubtitleChoice = nil
            return
        }
        // Same rule as mpv's `sub-auto=fuzzy`: any subtitle whose name starts with the video's.
        let stem = item.title.lowercased()
        externalSubtitles = siblings
            .filter { sibling in
                sibling.kind == .file
                    && sibling.mediaKind == .subtitle
                    && sibling.name.lowercased().hasPrefix(stem)
            }
            .map { source.playback(of: $0.url).location }
        // Later viewings restore whatever was chosen, including "off".
        if externalSubtitles.isEmpty || WatchHistory.shared.hasEntry(forLocation: location) {
            initialSubtitleChoice = nil
        } else {
            let codes = options.subtitleLanguage.codes?.split(separator: ",").map(String.init) ?? []
            initialSubtitleChoice = InitialSubtitleChoice(codes: codes, stem: item.title)
        }
    }

    /// Wraps a file opened in place, claiming security-scoped access for the playback's lifetime.
    init(openedInPlace url: URL) {
        location = url.path
        externalSubtitles = []
        forcesCache = false
        initialSubtitleChoice = nil
        itemURL = nil
        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    func endAccess() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}
