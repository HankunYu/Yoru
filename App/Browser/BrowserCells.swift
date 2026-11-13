import SwiftUI

/// The content of one browser cell, in either layout.
struct BrowserCell: View {
    let item: BrowserItem
    let mode: BrowserViewMode
    var isHighlighted = false
    /// Whether the item is picked for a batch action; nil when nothing is being picked.
    var isPicked: Bool?

    var body: some View {
        Group {
            switch item.kind {
            case .server: ServerCell(item: item, mode: mode)
            case .bookmark: BookmarkCell(item: item, mode: mode)
            case .folder: FolderCell(item: item, mode: mode)
            case .file: FileCell(item: item, mode: mode)
            }
        }
        .overlay(alignment: mode == .grid ? .topLeading : .trailing) {
            if let isPicked {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(isPicked ? .black : .white, isPicked ? Theme.accent : .clear)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .padding(mode == .grid ? 8 : 2)
            }
        }
        .opacity(mode == .grid && isHighlighted ? 0.6 : 1)
        .scaleEffect(mode == .grid && isHighlighted ? 0.97 : 1)
        .animation(.snappy(duration: 0.15), value: isHighlighted)
        // Cells are recycled; a new item must not inherit the previous one's loaded state.
        .id(item.url)
    }
}

// MARK: - Files

private struct FileCell: View {
    let item: BrowserItem
    let mode: BrowserViewMode

    @State private var preview: MediaPreview?
    private let history = WatchHistory.shared

    var body: some View {
        BrowserCellLayout(mode: mode, title: item.title) {
            MediaThumbnail(
                image: preview?.image,
                kind: item.mediaKind,
                label: item.url.pathExtension.uppercased(),
                cornerRadius: mode.coverCornerRadius,
                progress: progress,
                badge: mode == .grid && item.mediaKind != .image ? preview?.info.durationLabel : nil,
                // Only over a picture: the placeholder already shows the kind's symbol.
                badgeSymbol: item.mediaKind == .image && preview?.image != nil ? "photo" : nil,
                compactBadge: mode == .list
            )
        } detail: {
            HStack(spacing: 6) {
                Text(detail)
                    .lineLimit(1)
                if preview?.info.isHDR == true {
                    HDRTag()
                }
            }
        }
        .task {
            preview = MediaPreviewStore.shared.cachedPreview(for: item)
            if preview == nil {
                preview = await MediaPreviewStore.shared.preview(for: item)
            }
        }
        .animation(.easeOut(duration: 0.2), value: preview?.image != nil)
        // Files that cannot be opened recede.
        .opacity(item.mediaKind.isPlayable ? 1 : 0.5)
    }

    private var detail: String {
        var parts: [String] = []
        // A search result from further down says where: the whole way in a row, the
        // folder it is in on a tile, which has no room for more.
        if let context = item.context {
            parts.append(mode == .list ? context : (context as NSString).lastPathComponent)
        }
        if mode == .list, let duration = preview?.info.durationLabel {
            parts.append(duration)
        }
        if let resolution = preview?.info.resolutionLabel {
            parts.append(resolution)
        }
        let fileExtension = item.url.pathExtension
        if !fileExtension.isEmpty {
            parts.append(fileExtension.uppercased())
        }
        if let size = item.size {
            parts.append(Int64(size).formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    private var progress: Double? {
        guard let position = history.position(for: item.url),
              let duration = preview?.info.duration, duration > 0 else { return nil }
        return min(max(position / duration, 0), 1)
    }
}

private struct HDRTag: View {
    var body: some View {
        Text(verbatim: "HDR")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1)
            }
    }
}

// MARK: - Folders

private struct FolderCell: View {
    let item: BrowserItem
    let mode: BrowserViewMode

    @State private var peek: FolderPeek?
    @State private var covers: [UIImage] = []

    var body: some View {
        BrowserCellLayout(mode: mode, title: item.title) {
            FolderCover(covers: covers, cornerRadius: mode.coverCornerRadius)
        } detail: {
            if let context = item.context {
                Text(mode == .list ? context : (context as NSString).lastPathComponent)
                    .lineLimit(1)
            } else if let peek {
                Text("\(peek.count) items")
                    .lineLimit(1)
            }
        }
        .task {
            // Peeking into a remote folder would cost a round trip per folder shown.
            guard item.url.isFileURL else { return }
            let url = item.url
            let peek = await Task.detached(priority: .utility) { FolderPeek(url) }.value
            self.peek = peek
            var images: [UIImage] = []
            for file in peek.leadingFiles {
                if let image = await MediaPreviewStore.shared.preview(for: file)?.image {
                    images.append(image)
                    covers = images
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: covers.count)
    }
}

// MARK: - Bookmarks

private struct BookmarkCell: View {
    let item: BrowserItem
    let mode: BrowserViewMode

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: mode.coverCornerRadius, style: .continuous)
        BrowserCellLayout(mode: mode, title: item.title) {
            LinearGradient(
                colors: [Theme.accent.opacity(0.22), Theme.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(Theme.card)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: mode == .grid ? 28 : 18))
                    .foregroundStyle(Theme.accent.opacity(0.9))
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        } detail: {
            Text(location)
                .lineLimit(1)
        }
    }

    /// Where the bookmark leads, as a path a person would recognize.
    private var location: String {
        if item.url.isFileURL {
            let root = URL.documentsDirectory.standardizedFileURL.path
            return "YORU" + item.url.standardizedFileURL.path.dropFirst(root.count)
        }
        guard let (serverID, path) = MediaServer.parse(item.url) else { return "" }
        return ([ServerStore.shared.server(serverID)?.name ?? ""] + path).joined(separator: "/")
    }
}

// MARK: - Servers

private struct ServerCell: View {
    let item: BrowserItem
    let mode: BrowserViewMode

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: mode.coverCornerRadius, style: .continuous)
        BrowserCellLayout(mode: mode, title: item.title) {
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.17, blue: 0.30), Theme.card],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                Image(systemName: "server.rack")
                    .font(.system(size: mode == .grid ? 30 : 20))
                    .foregroundStyle(Theme.accent.opacity(0.9))
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
        } detail: {
            if let host {
                Text(host)
                    .lineLimit(1)
            }
        }
    }

    private var host: String? {
        guard let (serverID, _) = MediaServer.parse(item.url) else { return nil }
        return ServerStore.shared.server(serverID)?.address
    }
}

/// What a folder's cell needs to know about its contents.
private struct FolderPeek: Sendable {
    let count: Int
    /// The first few files by name, candidates for the cover.
    let leadingFiles: [BrowserItem]

    init(_ directory: URL) {
        let items = LocalSource.items(in: directory).sorted(by: .name)
        count = items.count
        leadingFiles = Array(items.lazy.filter { $0.kind == .file }.prefix(3))
    }
}

/// A folder's cover: its first videos as a stack of cards, or a plain card when it has none.
private struct FolderCover: View {
    let covers: [UIImage]
    let cornerRadius: CGFloat

    // Each card further back is narrower and peeks out above the one in front.
    private static let layers = 3
    private static let step: CGFloat = 0.06

    var body: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let rise = geometry.size.height * Self.step
                    let frontHeight = geometry.size.height - rise * CGFloat(Self.layers - 1)
                    ForEach((0..<Self.layers).reversed(), id: \.self) { depth in
                        let inset = geometry.size.width * Self.step * CGFloat(depth)
                        card(at: depth)
                            .frame(width: geometry.size.width - inset * 2, height: frontHeight)
                            .offset(x: inset, y: rise * CGFloat(Self.layers - 1 - depth))
                    }
                }
            }
    }

    @ViewBuilder
    private func card(at depth: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            Theme.card
            if depth < covers.count {
                Image(uiImage: covers[depth])
                    .resizable()
                    .scaledToFill()
            } else if depth == 0 {
                Image(systemName: "folder.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent.opacity(0.85))
            }
            // Cards further back recede into the dark.
            Color.black.opacity(0.3 * Double(depth))
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
    }
}

// MARK: - Shared pieces

/// Arranges a cover, title and detail line as a list row or a grid tile.
private struct BrowserCellLayout<Cover: View, Detail: View>: View {
    let mode: BrowserViewMode
    let title: String
    @ViewBuilder let cover: Cover
    @ViewBuilder let detail: Detail

    var body: some View {
        switch mode {
        case .list:
            HStack(spacing: 14) {
                cover
                    .frame(width: 112)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body)
                        .lineLimit(2)
                    detail
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        case .grid:
            VStack(alignment: .leading, spacing: 8) {
                cover
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    detail
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 2)
            }
        }
    }
}

/// A 16:9 frame from a file, with an optional resume-progress line and corner badge.
struct MediaThumbnail: View {
    let image: UIImage?
    /// Shown when there is no image: the kind's symbol over the file extension.
    let kind: MediaKind
    let label: String
    let cornerRadius: CGFloat
    var progress: Double?
    var badge: String?
    /// A symbol for the same corner, when there is no text to show.
    var badgeSymbol: String?
    /// The thumbnail is small (a list row), so the badge is too.
    var compactBadge = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    GeometryReader { geometry in
                        // Scaled with the tile, which is far smaller in the list than in the grid.
                        let unit = geometry.size.height
                        VStack(spacing: unit * 0.08) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: unit * 0.30, weight: .medium))
                            if !label.isEmpty {
                                Text(label)
                                    .font(.system(size: max(unit * 0.13, 8), weight: .bold, design: .rounded))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(kind.tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            LinearGradient(
                                colors: [kind.tint.opacity(0.16), Theme.card],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .background(Theme.card)
                        }
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                // One corner tells the kinds apart: a video shows its duration there, an
                // image a picture symbol.
                Group {
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.semibold).monospacedDigit())
                    } else if let badgeSymbol {
                        Image(systemName: badgeSymbol)
                            .font(.system(size: compactBadge ? 8 : 10, weight: .semibold))
                    }
                }
                .padding(.horizontal, compactBadge ? 4 : 6)
                .padding(.vertical, compactBadge ? 2 : 2.5)
                .background(.black.opacity(0.6), in: .capsule)
                .padding(compactBadge ? 3 : 6)
                .opacity(badge == nil && badgeSymbol == nil ? 0 : 1)
            }
            .overlay(alignment: .bottom) {
                if let progress {
                    Rectangle()
                        .fill(.white.opacity(0.25))
                        .frame(height: 3)
                        .overlay {
                            Theme.accent.scaleEffect(x: progress, anchor: .leading)
                        }
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5) }
    }
}

private extension BrowserViewMode {
    var coverCornerRadius: CGFloat {
        switch self {
        case .list: 8
        case .grid: 12
        }
    }
}
