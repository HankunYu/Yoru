import Foundation

/// The user-visible mpv config directory (`Documents/mpv`), exposed in the Files app.
///
/// Layout mirrors `~/.config/mpv` on Linux: `mpv.conf`, `input.conf`, `scripts/`,
/// `script-opts/`, `fonts/`, `watch_later/`.
enum ConfigDirectory {
    static let url = URL.documentsDirectory.appending(path: "mpv", directoryHint: .isDirectory)

    private static let subdirectories = ["scripts", "script-opts", "fonts", "watch_later"]
    // The bundled CJK font lives in `fonts/` like any user font: iOS sandboxing keeps libass
    // from opening system fonts (PingFang etc.), so without it CJK subtitles have no glyphs.
    private static let defaultFiles = [
        "mpv.conf", "input.conf", "script-opts/yoru.conf", "fonts/NotoSansCJKsc-Regular.otf",
    ]

    /// The bundled default for a config file, e.g. `mpv.conf`, if there is one.
    static func defaultContents(of relativePath: String) -> String? {
        guard let defaults = Bundle.main.url(forResource: "DefaultConfig", withExtension: nil) else { return nil }
        return try? String(contentsOf: defaults.appending(path: relativePath), encoding: .utf8)
    }

    /// Forgets every saved playback position.
    static func clearResumePositions() {
        let directory = url.appending(path: "watch_later", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static var resumePositionCount: Int {
        let directory = url.appending(path: "watch_later", directoryHint: .isDirectory)
        return (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    /// Creates the directory tree and copies bundled defaults for files that don't exist yet.
    /// Existing user files are never overwritten.
    static func prepare() {
        let fileManager = FileManager.default
        do {
            for name in subdirectories {
                try fileManager.createDirectory(
                    at: url.appending(path: name, directoryHint: .isDirectory),
                    withIntermediateDirectories: true
                )
            }
            guard let defaults = Bundle.main.url(forResource: "DefaultConfig", withExtension: nil) else {
                Log.app.error("DefaultConfig missing from bundle")
                return
            }
            for name in defaultFiles {
                let destination = url.appending(path: name)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: defaults.appending(path: name), to: destination)
                }
            }
        } catch {
            Log.app.error("Preparing config directory failed: \(error, privacy: .public)")
        }
    }
}
