import Foundation
import Observation

/// Finds out what downloading a selection involves: every file inside the picked folders,
/// how many there are, how large they are together, and how much of that a destination
/// already holds.
///
/// Servers cannot say how large a folder is; it takes one listing per folder, which reads
/// no file contents. The walk starts as soon as the plan is made, so the totals grow while
/// a destination is being chosen. Once one is chosen the files found so far are queued, and
/// the rest as they are found: nothing is listed twice.
///
/// Folders merge into existing ones of the same name, and a file already there with the
/// same size is left alone, so a download that was cancelled picks up where it stopped.
@MainActor
@Observable
final class DownloadPlan {
    /// Everything found so far.
    private(set) var fileCount = 0
    private(set) var totalBytes: Int64 = 0
    /// What `target` does not hold yet: the part that would actually be downloaded.
    private(set) var remainingCount = 0
    private(set) var remainingBytes: Int64 = 0
    private(set) var isComplete = false
    private(set) var failure: String?

    /// The folder the download would go into; the remaining figures are relative to it.
    var target = URL.documentsDirectory {
        didSet {
            if target != oldValue {
                recount()
            }
        }
    }

    private struct Entry {
        let item: BrowserItem
        /// The folders leading to the file, below the selection.
        let path: [String]
    }

    private let source: any MediaSource
    private var entries: [Entry] = []
    private var isCommitted = false
    private var task: Task<Void, Never>?

    init(items: [BrowserItem], source: any MediaSource) {
        self.source = source
        task = Task { [weak self] in
            do {
                for item in items where item.kind == .file {
                    self?.found(Entry(item: item, path: []))
                }
                for item in items where item.kind == .folder {
                    try await self?.walk(item.url, path: [item.name])
                }
            } catch is CancellationError {
                return
            } catch {
                self?.failure = error.localizedDescription
            }
            self?.isComplete = true
        }
    }

    /// Queues what `destination` lacks, recreating the folders there.
    func commit(to destination: URL) {
        target = destination
        isCommitted = true
        FileTransfers.shared.track(self)
        entries.forEach(queue)
    }

    /// Stops the walk; nothing more is queued. Has no effect on files already queued.
    func cancel() {
        task?.cancel()
        isCommitted = false
        isComplete = true
    }

    private func walk(_ directory: URL, path: [String]) async throws {
        try Task.checkCancellation()
        let contents = try await source.contents(of: directory)
        for item in contents where item.kind == .file {
            found(Entry(item: item, path: path))
        }
        for folder in contents where folder.kind == .folder {
            try await walk(folder.url, path: path + [folder.name])
        }
    }

    private func found(_ entry: Entry) {
        guard !Task.isCancelled else { return }
        entries.append(entry)
        fileCount += 1
        totalBytes += Int64(entry.item.size ?? 0)
        if isMissing(entry) {
            remainingCount += 1
            remainingBytes += Int64(entry.item.size ?? 0)
        }
        if isCommitted {
            queue(entry)
        }
    }

    private func recount() {
        let missing = entries.filter(isMissing)
        remainingCount = missing.count
        remainingBytes = missing.reduce(0) { $0 + Int64($1.item.size ?? 0) }
    }

    private func directory(for entry: Entry) -> URL {
        entry.path.reduce(target) { $0.appending(path: $1, directoryHint: .isDirectory) }
    }

    /// Whether `target` lacks the file, or holds one of a different size (an earlier
    /// attempt, or another file of that name), which is then replaced.
    private func isMissing(_ entry: Entry) -> Bool {
        let local = directory(for: entry).appending(path: entry.item.name)
        guard let size = (try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return true }
        return size != entry.item.size
    }

    private func queue(_ entry: Entry) {
        guard isMissing(entry), var transfer = source.transfer(of: entry.item) else { return }
        transfer.replacesExisting = true
        let directory = directory(for: entry)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileTransfers.shared.enqueue([transfer], into: directory)
        } catch {
            failure = error.localizedDescription
        }
    }
}
