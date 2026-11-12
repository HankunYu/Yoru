import SwiftUI

/// Where to go: the files of the folder being played through, and the chapters of the
/// current file. Tapping a row jumps there; the panel stays open.
struct ContentsPanel: View {
    let model: PlayerModel
    @State private var page = Page.playlist

    private enum Page {
        case playlist
        case chapters
    }

    var body: some View {
        SidePanelHeader(
            model: model,
            pages: [(Page.playlist, "Playlist"), (Page.chapters, "Chapters")],
            selection: $page
        )
        .onAppear {
            // Open on whichever list has something to show.
            if model.playlist.isEmpty, !model.chapters.isEmpty {
                page = .chapters
            }
        }
        switch page {
        case .playlist:
            list(
                rows: model.playlist.map { Entry(id: $0.id, title: $0.title, detail: nil) },
                current: model.playlistIndex,
                empty: "This file was opened on its own."
            ) { id in
                if let entry = model.playlist.first(where: { $0.id == id }) {
                    model.selectPlaylistEntry(entry)
                }
            }
        case .chapters:
            list(
                rows: model.chapters.map { Entry(id: $0.id, title: $0.title, detail: PlayerModel.format(time: $0.time)) },
                current: model.currentChapter,
                empty: "This file has no chapters."
            ) { id in
                if let chapter = model.chapters.first(where: { $0.id == id }) {
                    model.seek(to: chapter)
                }
            }
        }
    }

    private struct Entry: Identifiable {
        let id: Int
        let title: String
        let detail: String?
    }

    @ViewBuilder
    private func list(
        rows: [Entry], current: Int?, empty: LocalizedStringKey, select: @escaping (Int) -> Void
    ) -> some View {
        if rows.isEmpty {
            Text(empty)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(rows) { row in
                            Button {
                                select(row.id)
                            } label: {
                                ContentsRow(title: row.title, detail: row.detail, isCurrent: row.id == current)
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 20)
                }
                .sidePanelScrollFade()
                .onAppear {
                    if let current {
                        proxy.scrollTo(current, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct ContentsRow: View {
    let title: String
    let detail: String?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 14)
            Text(title)
                .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? Theme.accent : .white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .background(.white.opacity(isCurrent ? 0.12 : 0), in: .rect(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
