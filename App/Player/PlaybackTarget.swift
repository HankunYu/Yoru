import Foundation

/// Something the player can open: a location string handed to mpv's `loadfile` verbatim.
struct PlaybackTarget: Identifiable {
    let id = UUID()
    /// A file path or any URL mpv understands (`smb://`, `http://`, `dav://`, ...).
    let location: String
    /// Set when the file was opened in place from another app (Files, a file provider);
    /// access must be released with `endAccess()` when playback ends.
    private let securityScopedURL: URL?

    init(location: String) {
        self.location = location
        securityScopedURL = nil
    }

    init(fileURL: URL) {
        location = fileURL.path
        securityScopedURL = nil
    }

    /// Wraps a file opened in place, claiming security-scoped access for the playback's lifetime.
    init(openedInPlace url: URL) {
        location = url.path
        securityScopedURL = url.startAccessingSecurityScopedResource() ? url : nil
    }

    func endAccess() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
    }
}
