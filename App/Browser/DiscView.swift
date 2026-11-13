import SwiftUI

/// What a Blu-ray folder shows in place of its files: the titles on the disc.
struct DiscView: View {
    let disc: BlurayDisc
    let onPlay: (BlurayDisc.Title) -> Void

    var body: some View {
        ScrollView {
            // Lazy, so a title's frame is made when its row comes into view: each costs
            // opening a clip, and a disc can hold dozens.
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(disc.titles) { title in
                    Button { onPlay(title) } label: {
                        DiscTitleRow(title: title, label: disc.label(of: title), cover: disc.coverClip(of: title))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct DiscTitleRow: View {
    let title: BlurayDisc.Title
    let label: String
    let cover: URL?

    @State private var preview: MediaPreview?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MediaThumbnail(
                image: preview?.image, kind: .video, label: "",
                cornerRadius: 10, progress: nil, badge: nil, badgeSymbol: nil, compactBadge: true
            )
            .frame(width: 128)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(summary)
                    .monospacedDigit()
                if !audio.isEmpty {
                    Text("Audio: \(audio)")
                }
                if !subtitles.isEmpty {
                    Text("Subtitles: \(subtitles)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .task {
            guard let cover else { return }
            let item = BrowserItem(url: cover, kind: .file, name: cover.lastPathComponent, size: nil, modified: nil)
            preview = MediaPreviewStore.shared.cachedPreview(for: item)
            if preview == nil {
                preview = await MediaPreviewStore.shared.preview(for: item)
            }
        }
    }

    private var playlist: BlurayPlaylist { title.playlist }

    private var summary: String {
        var parts = [PlayerModel.format(time: playlist.duration)]
        if let video = playlist.streams.video {
            parts.append([video.format, video.codec].compactMap { $0 }.joined(separator: " "))
        }
        if playlist.chapters.count > 1 {
            parts.append(String(localized: "\(playlist.chapters.count) chapters"))
        }
        return parts.joined(separator: " · ")
    }

    private var audio: String {
        playlist.streams.audio.map { stream in
            ([DiscLanguage.name(of: stream.language), stream.codec] + [stream.channels].compactMap { $0 }).joined(separator: " ")
        }.joined(separator: ", ")
    }

    /// Each language once: discs often carry several subtitles in one.
    private var subtitles: String {
        var seen: Set<String> = []
        return playlist.streams.subtitles.map(\.language).filter { seen.insert($0).inserted }
            .map(DiscLanguage.name(of:)).joined(separator: ", ")
    }
}

extension BlurayDisc {
    /// What to call a title: the disc's own name for it, or what its length makes it.
    func label(of title: Title) -> String {
        if let name = title.name { return name }
        switch title.role {
        case .feature:
            return featureCount == 1 ? String(localized: "Main Feature") : String(localized: "Feature \(title.number)")
        case .extra:
            return String(localized: "Extra \(title.number)")
        }
    }
}

/// Names the three-letter language codes discs use.
enum DiscLanguage {
    static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }
}
