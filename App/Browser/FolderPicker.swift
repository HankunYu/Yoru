import SwiftUI

/// Sheet for choosing a folder of the local library, as the destination of a move or a
/// download.
struct FolderPicker: View {
    let title: LocalizedStringKey
    let confirmation: LocalizedStringKey
    /// Folders that cannot be chosen, along with everything inside them: a folder cannot be
    /// moved into itself.
    let excluded: [URL]
    /// For a download: what is being fetched, counted while this sheet is open.
    var plan: DownloadPlan?
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folders: [(url: URL, depth: Int)] = []
    @State private var picked = URL.documentsDirectory
    @State private var didPick = false

    private var freeBytes: Int64 {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    var body: some View {
        NavigationStack {
            List {
                if let plan {
                    Section {
                        DownloadSummary(plan: plan, freeBytes: freeBytes)
                            .listRowBackground(Theme.card)
                    }
                }
                row(URL.documentsDirectory, name: "YORU", depth: 0, symbol: "house")
                ForEach(folders, id: \.url) { folder in
                    row(folder.url, name: folder.url.lastPathComponent, depth: folder.depth + 1, symbol: "folder")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmation) {
                        didPick = true
                        onPick(picked)
                        dismiss()
                    }
                    // Counting may still be running; what is known already is enough to refuse.
                    .disabled((plan?.remainingBytes ?? 0) > freeBytes)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task {
            folders = LocalSource.folders(in: .documentsDirectory)
        }
        // What is left to download depends on what the chosen folder already holds.
        .onChange(of: picked, initial: true) { plan?.target = picked }
        .onDisappear {
            // Dismissed without choosing: nothing will be downloaded, so stop counting.
            if !didPick {
                plan?.cancel()
            }
        }
    }

    private func row(_ url: URL, name: String, depth: Int, symbol: String) -> some View {
        let isExcluded = excluded.contains { url.path == $0.path || url.path.hasPrefix($0.path + "/") }
        return Button {
            picked = url
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if picked == url {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.leading, CGFloat(depth) * 20)
        }
        .disabled(isExcluded)
        .opacity(isExcluded ? 0.4 : 1)
        .listRowBackground(Theme.card)
    }
}

/// How much a download amounts to, against the space left on the device.
private struct DownloadSummary: View {
    let plan: DownloadPlan
    let freeBytes: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(plan.remainingCount) files, \(plan.remainingBytes.formatted(.byteCount(style: .file)))")
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                if !plan.isComplete {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if plan.fileCount > plan.remainingCount {
                Text("\(plan.fileCount - plan.remainingCount) already in this folder will be skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure = plan.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Free space: \(freeBytes.formatted(.byteCount(style: .file)))")
                .font(.caption)
                .foregroundStyle(plan.remainingBytes > freeBytes ? .red : .secondary)
            if plan.remainingBytes > freeBytes {
                Text("There is not enough free space for this download.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
