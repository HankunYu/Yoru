import Foundation
import Observation

/// Saved resume positions, read from mpv's `watch_later` files.
///
/// mpv names those files by a hash of the media path; with
/// `write-filename-in-watch-later-config` each one also starts with `# <path>`, which is
/// what makes them readable here.
@MainActor
@Observable
final class WatchHistory {
    static let shared = WatchHistory()

    /// Resume position in seconds, keyed by normalized file path.
    private var positions: [String: Double] = [:]
    /// Every location with a resume file, whatever it holds.
    private var locations: Set<String> = []

    private init() {
        reload()
    }

    func position(for url: URL) -> Double? {
        positions[Self.normalize(url.path)]
    }

    /// Whether anything is remembered for a location as given to mpv: a file path or a URL.
    func hasEntry(forLocation location: String) -> Bool {
        locations.contains(Self.normalize(location))
    }

    func reload() {
        Task {
            (positions, locations) = await Task.detached(priority: .utility) { Self.readEntries() }.value
        }
    }

    // MARK: - Private

    private nonisolated static func readEntries() -> (positions: [String: Double], locations: Set<String>) {
        let directory = ConfigDirectory.url.appending(path: "watch_later", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var positions: [String: Double] = [:]
        var locations: Set<String> = []
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var path: String?
            var start: Double?
            for line in text.split(separator: "\n") {
                if path == nil, line.hasPrefix("# ") {
                    path = String(line.dropFirst(2))
                } else if line.hasPrefix("start=") {
                    start = Double(line.dropFirst("start=".count))
                }
            }
            if let path {
                locations.insert(normalize(path))
                if let start {
                    positions[normalize(path)] = start
                }
            }
        }
        return (positions, locations)
    }

    /// `/private/var/...` and `/var/...` name the same file.
    private nonisolated static func normalize(_ path: String) -> String {
        path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
