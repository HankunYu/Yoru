import CryptoKit
import Foundation

/// Maintenance of mpv's `watch_later` files.
enum ResumePositions {
    /// Re-keys the resume files of the app's own files after its data container moved.
    ///
    /// mpv names a resume file by the MD5 of the media's absolute path, and iOS gives the
    /// app a new container path whenever it is reinstalled (as every build from Xcode is),
    /// so each reinstall would otherwise forget where local videos were left off. Entries
    /// written with `write-filename-in-watch-later-config` start with `# <path>`; those
    /// pointing into another container are rewritten for `containerID` and renamed.
    ///
    /// Redirect entries are removed along the way: they let mpv resume a directory given
    /// as a playlist, which the app never does, and they are written on every playback.
    static func rebase(in directory: URL, containerID: String) {
        let fileManager = FileManager.default
        let files = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        // The newest stale entry for each rebased path.
        var moved: [String: (file: URL, modified: Date, body: Substring)] = [:]
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let (header, body) = text.splitFirstLine()
            if header == "# redirect entry" {
                try? fileManager.removeItem(at: file)
                continue
            }
            guard header.hasPrefix("# "),
                  let match = header.dropFirst(2).wholeMatch(of: containerPath),
                  match.2.caseInsensitiveCompare(containerID) != .orderedSame else { continue }
            let path = "\(match.1)\(containerID)\(match.3)"
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            if let other = moved[path], other.modified >= modified {
                try? fileManager.removeItem(at: file)
            } else {
                if let other = moved[path] {
                    try? fileManager.removeItem(at: other.file)
                }
                moved[path] = (file, modified, body)
            }
        }

        for (path, entry) in moved {
            let target = directory.appending(path: fileName(for: path))
            // A position saved since the move is newer than anything carried over.
            if !fileManager.fileExists(atPath: target.path) {
                try? "# \(path)\n\(entry.body)".write(to: target, atomically: true, encoding: .utf8)
            }
            try? fileManager.removeItem(at: entry.file)
        }
    }

    /// The name mpv gives the resume file of `path`: its MD5 in upper-case hex.
    static func fileName(for path: String) -> String {
        Insecure.MD5.hash(data: Data(path.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    /// An absolute path inside an app data container: up to the container ID, the ID, the rest.
    private nonisolated(unsafe) static let containerPath =
        #/^(.*/Containers/Data/Application/)([0-9A-Fa-f-]{36})(/.*)$/#
}

private extension String {
    /// The first line and everything after its line break.
    func splitFirstLine() -> (header: Substring, body: Substring) {
        guard let lineBreak = firstIndex(of: "\n") else { return (self[...], "") }
        return (self[..<lineBreak], self[index(after: lineBreak)...])
    }
}
