import Foundation
import Observation

/// Copies files picked from other locations (Files, network shares) into a directory,
/// off the main thread, with progress and cancellation.
@MainActor
@Observable
final class FileImporter {
    struct Progress: Equatable {
        var fileName: String
        /// 1-based index of the file being copied and the total number of files.
        var index: Int
        var count: Int
        var copiedBytes: Int64
        var totalBytes: Int64

        var fraction: Double {
            totalBytes > 0 ? min(Double(copiedBytes) / Double(totalBytes), 1) : 0
        }
    }

    private(set) var progress: Progress?
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?

    var isImporting: Bool { progress != nil }

    /// Starts copying `urls` into `directory`, skipping files already inside the library. `onFinished` runs once, after the last file
    /// (or after cancellation), so the caller can refresh its listing.
    func start(_ urls: [URL], into directory: URL, onFinished: @escaping @MainActor () -> Void) {
        // The picker also shows the app's own folder; those files are in the library already,
        // and copying them would only make duplicates.
        let urls = urls.filter { !Self.isInLibrary($0) }
        guard task == nil, !urls.isEmpty else { return }
        errorMessage = nil
        task = Task {
            for (offset, url) in urls.enumerated() {
                if Task.isCancelled { break }
                do {
                    try await copy(url, into: directory, index: offset + 1, count: urls.count)
                } catch is CancellationError {
                    break
                } catch {
                    Log.app.error("Import failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                    errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            progress = nil
            task = nil
            onFinished()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func dismissError() {
        errorMessage = nil
    }

    private func copy(_ source: URL, into directory: URL, index: Int, count: Int) async throws {
        // Picked files stay readable only while their security scope is held.
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let name = source.lastPathComponent
        let totalBytes = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        progress = Progress(fileName: name, index: index, count: count, copiedBytes: 0, totalBytes: totalBytes)

        let destination = Self.availableURL(for: name, in: directory)
        // Hidden while incomplete, so a half-copied file never shows up in the listing.
        let partial = directory.appending(path: ".\(name).importing")

        try await Task.detached(priority: .userInitiated) {
            try Self.streamCopy(from: source, to: partial) { copied in
                Task { @MainActor [weak self] in
                    self?.progress?.copiedBytes = copied
                }
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        }.value
    }

    /// Copies in chunks so progress can be reported and cancellation honored. Removes the
    /// partial file on any failure.
    private nonisolated static func streamCopy(
        from source: URL, to destination: URL, onProgress: @Sendable (Int64) -> Void
    ) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        fileManager.createFile(atPath: destination.path, contents: nil)
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }

            var copied: Int64 = 0
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                onProgress(copied)
            }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private static func isInLibrary(_ url: URL) -> Bool {
        // Resolved on both sides: the picker may spell the container as `/private/var/...`.
        let library = URL.documentsDirectory.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(library + "/")
    }

    /// `name`, or `name 2`, `name 3`, ... if a file with that name already exists.
    private nonisolated static func availableURL(for name: String, in directory: URL) -> URL {
        let fileManager = FileManager.default
        var candidate = directory.appending(path: name)
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let numbered = pathExtension.isEmpty ? "\(base) \(suffix)" : "\(base) \(suffix).\(pathExtension)"
            candidate = directory.appending(path: numbered)
            suffix += 1
        }
        return candidate
    }
}
