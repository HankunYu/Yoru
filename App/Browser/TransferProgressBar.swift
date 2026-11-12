import SwiftUI

/// Bar shown along the bottom of the browser while files are being imported or downloaded.
struct TransferProgressBar: View {
    let progress: FileTransfers.Progress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(progress.fileName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                ProgressView(value: progress.fraction)
                    .tint(Theme.accent)
            }
            Button("Cancel", systemImage: "xmark.circle.fill", action: onCancel)
                .labelStyle(.iconOnly)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var detail: String {
        let copied = ByteCountFormatter.string(fromByteCount: progress.copiedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
        let position = progress.count > 1 ? "\(progress.index)/\(progress.count) · " : ""
        let rate = progress.bytesPerSecond > 0
            ? " · \(ByteCountFormatter.string(fromByteCount: progress.bytesPerSecond, countStyle: .file))/s" : ""
        return "\(position)\(copied) / \(total)\(rate)"
    }
}
