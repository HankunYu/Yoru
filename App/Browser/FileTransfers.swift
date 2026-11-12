import Foundation
import Observation

/// Something to bring into the local library: where it comes from and how to fetch it.
struct FileTransfer: Sendable {
    let name: String
    /// The size in bytes, if known up front.
    let totalBytes: Int64
    /// Take the place of a file of the same name at the destination, instead of being
    /// saved beside it under a numbered name.
    var replacesExisting = false
    /// Writes the whole file to `destination`, reporting bytes written so far. Runs off the
    /// main thread and must honor task cancellation; the caller removes a partial file.
    let perform: @Sendable (_ destination: URL, _ progress: @Sendable (Int64) -> Void) async throws -> Void
}

/// Copies files into the local library one after another: files picked from other apps, and
/// files downloaded from servers. Shared by the whole app, so a transfer keeps running and
/// stays visible while the browser moves elsewhere.
@MainActor
@Observable
final class FileTransfers {
    static let shared = FileTransfers()

    struct Progress: Equatable {
        var fileName: String
        /// 1-based index of the file being copied and the number queued so far.
        var index: Int
        var count: Int
        var copiedBytes: Int64
        var totalBytes: Int64
        /// The current rate, averaged over the last couple of seconds; 0 until measured.
        var bytesPerSecond: Int64 = 0

        var fraction: Double {
            totalBytes > 0 ? min(Double(copiedBytes) / Double(totalBytes), 1) : 0
        }
    }

    private(set) var progress: Progress?
    private(set) var errorMessage: String?
    /// Counts finished files; browsers watch it to refresh their listings.
    private(set) var completed = 0

    private var queue: [(transfer: FileTransfer, directory: URL)] = []
    private var finishedInBatch = 0
    private var task: Task<Void, Never>?
    // Bytes written since the batch began, across files, for measuring the rate.
    private var batchBytes: Int64 = 0
    private var rateTask: Task<Void, Never>?
    // Plans that may still add to the queue.
    private var plans: [DownloadPlan] = []

    var isActive: Bool { progress != nil }

    private init() {}

    /// Queues `transfers` to be written into `directory`.
    func enqueue(_ transfers: [FileTransfer], into directory: URL) {
        guard !transfers.isEmpty else { return }
        errorMessage = nil
        queue += transfers.map { ($0, directory) }
        if task == nil {
            start()
        } else {
            progress?.count = finishedInBatch + queue.count + 1
        }
    }

    /// Works through the queue until it is empty or cancelled.
    private func start() {
        finishedInBatch = 0
        batchBytes = 0
        measureRate()
        task = Task {
            while !queue.isEmpty, !Task.isCancelled {
                let (transfer, directory) = queue.removeFirst()
                do {
                    try await run(transfer, into: directory)
                } catch {
                    // A cancelled download surfaces as whatever its source throws, not
                    // always as CancellationError; either way it is not a failure to report.
                    if Task.isCancelled || error is CancellationError { break }
                    Log.app.error("Transfer of \(transfer.name, privacy: .public) failed: \(error, privacy: .public)")
                    errorMessage = "\(transfer.name): \(error.localizedDescription)"
                }
                finishedInBatch += 1
                completed += 1
            }
            progress = nil
            task = nil
            rateTask?.cancel()
            rateTask = nil
            completed += 1
            // Anything queued while a cancelled batch was still winding down starts afresh.
            if !queue.isEmpty {
                start()
            }
        }
    }

    /// Stops the current transfer and drops the rest of the queue, including what plans
    /// still walking a folder would have added.
    func cancel() {
        for plan in plans {
            plan.cancel()
        }
        plans = []
        queue = []
        task?.cancel()
    }

    /// Registers a plan that will keep adding transfers, so `cancel()` can stop it.
    func track(_ plan: DownloadPlan) {
        plans.removeAll { $0.isComplete }
        plans.append(plan)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func run(_ transfer: FileTransfer, into directory: URL) async throws {
        progress = Progress(
            fileName: transfer.name,
            index: finishedInBatch + 1,
            count: finishedInBatch + queue.count + 1,
            copiedBytes: 0,
            totalBytes: transfer.totalBytes,
            // Carried over from the previous file, so the figure does not blink away.
            bytesPerSecond: progress?.bytesPerSecond ?? 0
        )
        let destination = transfer.replacesExisting
            ? directory.appending(path: transfer.name)
            : Self.availableURL(for: transfer.name, in: directory)
        let replacesExisting = transfer.replacesExisting
        // Hidden while incomplete, so a half-written file never shows up in the listing.
        let partial = directory.appending(path: ".\(transfer.name).partial")

        // A detached task does not inherit cancellation, so it is passed on by hand:
        // without this the copy ran to its end after "cancel".
        let work = Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try? fileManager.removeItem(at: partial)
            do {
                try await transfer.perform(partial) { copied in
                    Task { @MainActor in
                        FileTransfers.shared.advance(to: copied)
                    }
                }
                try Task.checkCancellation()
                if replacesExisting {
                    try? fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: partial, to: destination)
            } catch {
                try? fileManager.removeItem(at: partial)
                throw error
            }
        }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func advance(to copied: Int64) {
        guard let current = progress?.copiedBytes, copied > current else { return }
        batchBytes += copied - current
        progress?.copiedBytes = copied
    }

    /// Samples the bytes written once a second for as long as the batch runs. Each reading
    /// is averaged with the previous one, so the figure does not jump with every chunk.
    private func measureRate() {
        rateTask?.cancel()
        rateTask = Task { [weak self] in
            var last: Int64 = 0
            var rate: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                let sample = batchBytes - last
                last = batchBytes
                rate = rate == 0 ? sample : (rate + sample) / 2
                progress?.bytesPerSecond = rate
            }
        }
    }

    /// `name`, or `name 2`, `name 3`, ... if a file with that name already exists.
    nonisolated static func availableURL(for name: String, in directory: URL) -> URL {
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

extension FileTransfer {
    /// A file picked from another app, readable only while its security scope is held.
    /// Returns nil for a file that is already inside the library: copying it would only
    /// make a duplicate.
    init?(importing source: URL) {
        // Resolved on both sides: the picker may spell the container as `/private/var/...`.
        let library = URL.documentsDirectory.resolvingSymlinksInPath().path
        guard !source.resolvingSymlinksInPath().path.hasPrefix(library + "/") else { return nil }
        let accessing = source.startAccessingSecurityScopedResource()
        let size = Int64((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if accessing { source.stopAccessingSecurityScopedResource() }
        self.init(name: source.lastPathComponent, totalBytes: size) { destination, progress in
            let accessing = source.startAccessingSecurityScopedResource()
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try FileTransfer.write(to: destination, progress: progress) {
                try input.read(upToCount: 4 << 20) ?? Data()
            }
        }
    }

    /// Writes chunks to `destination` until `next` returns an empty one, reporting progress
    /// and checking for cancellation between chunks.
    static func write(
        to destination: URL, progress: (Int64) -> Void, next: () throws -> Data
    ) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var written: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try next()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            written += Int64(chunk.count)
            progress(written)
        }
    }
}
