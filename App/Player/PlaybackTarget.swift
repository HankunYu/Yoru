import Foundation

/// Something the player can open: a location string handed to mpv's `loadfile` verbatim.
struct PlaybackTarget: Identifiable {
    let id = UUID()
    /// A file path or any URL mpv understands (`smb://`, `http://`, `dav://`, ...).
    let location: String
    /// Subtitle files to attach once the file is loaded. mpv finds same-folder subtitles
    /// itself only for local files; for other sources the browser supplies them.
    let externalSubtitles: [String]
    /// Whether to turn mpv's cache on explicitly. It does so on its own for network URLs it
    /// opens itself, but streams served by the app look local to it.
    let forcesCache: Bool
    /// Set when the file was opened in place from another app (Files, a file provider);
    /// access must be released with `endAccess()` when playback ends.
    private let securityScopedURL: URL?

    init(location: String) {
        self.location = location
        externalSubtitles = []
        forcesCache = false
        securityScopedURL = nil
    }

    /// A file picked in the browser, with the other items of its folder.
    init(item: BrowserItem, siblings: [BrowserItem]) {
        securityScopedURL = nil
        guard !item.url.isFileURL else {
            location = item.url.path
            externalSubtitles = []
            forcesCache = false
            return
        }
        location = item.url.absoluteString
        forcesCache = true
        guard PlayerOptions.load().loadsExternalSubtitles else {
            externalSubtitles = []
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
            .map(\.url.absoluteString)
    }

    /// Wraps a file opened in place, claiming security-scoped access for the playback's lifetime.
    init(openedInPlace url: URL) {
        location = url.path
        externalSubtitles = []
        forcesCache = false
        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    func endAccess() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}
