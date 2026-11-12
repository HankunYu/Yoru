import SwiftUI
import UniformTypeIdentifiers

/// Lists one directory of a media source: the app's Documents folder, or a folder on a server.
/// The Documents root also lists the saved servers.
struct BrowserView: View {
    let directory: URL
    @Binding var playing: PlaybackTarget?
    @Binding var path: [BrowserItem]
    @Environment(\.scenePhase) private var scenePhase

    @State private var items: [BrowserItem] = []
    @State private var isLoading = true
    @State private var failure: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var isImporting = false
    @State private var isEnteringLocation = false
    @State private var enteredLocation = ""
    @State private var isNamingFolder = false
    @State private var enteredName = ""
    @State private var renamedItem: BrowserItem?
    // Items waiting for a destination folder: to be moved there, or downloaded there.
    @State private var relocation: Relocation?
    // Non-nil while items are being picked for a batch action.
    @State private var selection: Set<URL>?
    @State private var operationFailure: String?
    private let transfers = FileTransfers.shared
    @State private var isShowingSettings = false
    @State private var isAddingServer = false
    @State private var editedServer: MediaServer?
    // App UI state, not mpv configuration, so it lives in UserDefaults.
    @AppStorage("browser.viewMode") private var viewMode = BrowserViewMode.grid
    @AppStorage("browser.sortOrder") private var sortOrder = BrowserSortOrder.name
    @AppStorage("browser.mediaOnly") private var showsMediaOnly = false
    private let servers = ServerStore.shared
    private let bookmarks = BookmarkStore.shared

    private struct Relocation: Identifiable {
        enum Purpose {
            case move
            case download
        }

        let id = UUID()
        let items: [BrowserItem]
        let purpose: Purpose
        /// For a download: counts what is inside the items from the moment it is asked for.
        var plan: DownloadPlan?
    }

    private func downloading(_ items: [BrowserItem]) -> Relocation {
        Relocation(items: items, purpose: .download, plan: DownloadPlan(items: items, source: source))
    }

    private var source: any MediaSource { MediaSources.source(for: directory) }
    /// What the listing shows: everything, or without the files that cannot be played.
    /// `items` stays complete, since a video's subtitles are found among them.
    private var visibleItems: [BrowserItem] {
        showsMediaOnly ? items.filter { $0.kind != .file || $0.mediaKind == .video || $0.mediaKind == .audio } : items
    }
    private var pickedItems: [BrowserItem] { visibleItems.filter { selection?.contains($0.url) == true } }
    private var isRoot: Bool { directory == URL.documentsDirectory }
    private var isLocal: Bool { directory.isFileURL }
    private var currentServer: MediaServer? {
        MediaServer.parse(directory).flatMap { servers.server($0.serverID) }
    }

    private var title: String {
        if isRoot { return "YORU" }
        if let (serverID, path) = MediaServer.parse(directory), path.isEmpty {
            return servers.server(serverID)?.name ?? ""
        }
        return directory.lastPathComponent
    }

    var body: some View {
        BrowserList(
            items: visibleItems, mode: viewMode, selection: selection,
            canDelete: canDelete, onSelect: open, onDelete: delete, actions: { actions(for: $0) }
        )
            .ignoresSafeArea()
            .background { BrowserBackground() }
        .safeAreaInset(edge: .bottom) {
            if selection != nil {
                selectionBar
            }
        }
        .alert("Could Not Complete", isPresented: Binding(
            get: { operationFailure != nil }, set: { if !$0 { operationFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationFailure ?? "")
        }
        .overlay {
            if let failure {
                ContentUnavailableView {
                    Label("Could Not Connect", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Retry") { reload() }
                        .buttonStyle(.glass)
                }
            } else if isLoading {
                ProgressView()
            } else if visibleItems.isEmpty, isLocal, items.isEmpty {
                ContentUnavailableView {
                    Label("No Files", systemImage: "moon.stars")
                } description: {
                    Text("Copy videos into YORU with the Files app, or import them here.")
                } actions: {
                    Button("Import") { isImporting = true }
                        .buttonStyle(.glass)
                }
            } else if visibleItems.isEmpty {
                ContentUnavailableView("No Files", systemImage: "tray")
            }
        }
        .navigationTitle(title)
        .toolbar {
            // Settings sits in its own glass group, apart from the browsing actions.
            if isRoot {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
                }
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            if selection != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selection = nil }
                }
            } else {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu("More", systemImage: "ellipsis") {
                        Picker("View", selection: $viewMode) {
                            Label("Grid", systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
                            Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                        }
                        .pickerStyle(.inline)
                        Picker("Sort By", selection: $sortOrder) {
                            Label("Name", systemImage: "tag").tag(BrowserSortOrder.name)
                            Label("Date", systemImage: "calendar").tag(BrowserSortOrder.date)
                            Label("Size", systemImage: "internaldrive").tag(BrowserSortOrder.size)
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Picker("Show", selection: $showsMediaOnly) {
                            Label("All Files", systemImage: "doc.on.doc").tag(false)
                            Label("Video and Audio Only", systemImage: "play.rectangle").tag(true)
                        }
                        .pickerStyle(.inline)
                        Divider()
                        if visibleItems.contains(where: { $0.kind == .folder || $0.kind == .file }) {
                            Button("Select", systemImage: "checkmark.circle") { selection = [] }
                        }
                        if !isRoot {
                            if let bookmark = bookmarks.bookmark(for: directory) {
                                Button("Remove Bookmark", systemImage: "bookmark.slash") { bookmarks.remove(bookmark.id) }
                            } else {
                                Button("Bookmark This Folder", systemImage: "bookmark") {
                                    bookmarks.add(directory, name: title)
                                }
                            }
                        }
                        if isLocal {
                            Button("New Folder", systemImage: "folder.badge.plus") {
                                enteredName = ""
                                isNamingFolder = true
                            }
                        }
                    }
                    if isRoot {
                        Button("Add Server", systemImage: "server.rack") { isAddingServer = true }
                    }
                    if isLocal {
                        Button("Open Location", systemImage: "link") { isEnteringLocation = true }
                    } else {
                        // Back to the server's top level, which can be many folders up. The
                        // path is rebuilt rather than trimmed: a bookmark leads straight
                        // into a folder, without the server as its first step.
                        Button("Home", systemImage: "house") {
                            if let server = currentServer {
                                path = [BrowserItem(server: server)]
                            }
                        }
                        .disabled(currentServer.map { $0.rootURL == directory } ?? true)
                    }
                    if isLocal {
                        Button("Import", systemImage: "plus") { isImporting = true }
                    }
                }
            }
        }
        .alert("New Folder", isPresented: $isNamingFolder) {
            TextField("Name", text: $enteredName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(get: { renamedItem != nil }, set: { if !$0 { renamedItem = nil } })) {
            TextField("Name", text: $enteredName)
                .autocorrectionDisabled()
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $relocation) { relocation in
            FolderPicker(
                title: relocation.purpose == .move ? "Move To" : "Download To",
                confirmation: relocation.purpose == .move ? "Move" : "Download",
                excluded: relocation.purpose == .move ? relocation.items.map(\.url) : [],
                plan: relocation.plan
            ) { folder in
                finish(relocation, in: folder)
            }
        }
        .sheet(isPresented: $isAddingServer) {
            ServerEditorView()
        }
        .sheet(item: $editedServer) { server in
            ServerEditorView(editing: server)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .alert("Open Location", isPresented: $isEnteringLocation) {
            TextField("URL", text: $enteredLocation, prompt: Text(verbatim: "https://example.com/video.mp4"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Play") {
                let location = enteredLocation.trimmingCharacters(in: .whitespacesAndNewlines)
                if !location.isEmpty {
                    playing = PlaybackTarget(location: location)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the address of a video or stream. Supported: http, https (including HLS and DASH streams), ftp, rtsp and rtmp.")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .onAppear { reload() }
        // Files may have been added or removed through the Files app meanwhile.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .onChange(of: sortOrder) { items = items.sorted(by: sortOrder) }
        .onChange(of: servers.servers) { if isRoot { reload() } }
        .onChange(of: bookmarks.bookmarks) { if isRoot { reload() } }
        .onChange(of: transfers.completed) { if isLocal { reload() } }
        .onDisappear { loadTask?.cancel() }
    }

    private func reload() {
        WatchHistory.shared.reload()
        loadTask?.cancel()
        loadTask = Task {
            do {
                var loaded = try await source.contents(of: directory)
                if isRoot {
                    loaded += servers.servers.map(BrowserItem.init(server:))
                    bookmarks.removeMissingLocalFolders()
                    loaded += bookmarks.bookmarks.compactMap(BrowserItem.init(bookmark:))
                }
                guard !Task.isCancelled else { return }
                items = loaded.sorted(by: sortOrder)
                failure = nil
            } catch {
                guard !Task.isCancelled else { return }
                items = []
                failure = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        transfers.enqueue(urls.compactMap(FileTransfer.init(importing:)), into: directory)
    }

    private func open(_ item: BrowserItem) {
        if selection != nil {
            // Servers and bookmarks are not files: they take no part in batch actions.
            guard item.kind == .folder || item.kind == .file else { return }
            if selection?.remove(item.url) == nil {
                selection?.insert(item.url)
            }
        } else if item.isDirectory {
            path.append(item)
        } else if item.mediaKind.isPlayable {
            var target = PlaybackTarget(item: item, siblings: items)
            target.queue = PlaybackQueue(startingAt: item, among: items)
            playing = target
        }
    }

    // MARK: - Actions

    /// The long-press menu of an item.
    private func actions(for item: BrowserItem) -> [BrowserAction] {
        if item.kind == .server {
            return [
                BrowserAction(title: String(localized: "Edit"), symbol: "pencil") { edit(item) },
                deleteAction(for: item),
            ]
        }
        if item.kind == .bookmark {
            return [
                BrowserAction(title: String(localized: "Rename"), symbol: "pencil") {
                    enteredName = item.name
                    renamedItem = item
                },
                BrowserAction(title: String(localized: "Remove Bookmark"), symbol: "bookmark.slash", isDestructive: true) {
                    delete(item)
                },
            ]
        }
        // Any folder can be bookmarked, local or on a server.
        let bookmarking: [BrowserAction] = item.kind != .folder ? [] : [
            bookmarks.bookmark(for: item.url).map { bookmark in
                BrowserAction(title: String(localized: "Remove Bookmark"), symbol: "bookmark.slash") {
                    bookmarks.remove(bookmark.id)
                }
            } ?? BrowserAction(title: String(localized: "Add Bookmark"), symbol: "bookmark") {
                bookmarks.add(item.url, name: item.name)
            },
        ]
        if isLocal {
            return [
                BrowserAction(title: String(localized: "Rename"), symbol: "pencil") {
                    enteredName = item.name
                    renamedItem = item
                },
                BrowserAction(title: String(localized: "Move"), symbol: "folder") {
                    relocation = Relocation(items: [item], purpose: .move)
                },
            ] + bookmarking + [deleteAction(for: item)]
        }
        return [
            BrowserAction(title: String(localized: "Download"), symbol: "arrow.down.circle") {
                relocation = downloading([item])
            },
        ] + bookmarking
    }

    private func deleteAction(for item: BrowserItem) -> BrowserAction {
        BrowserAction(title: String(localized: "Delete"), symbol: "trash", isDestructive: true) { delete(item) }
    }

    /// The bar of batch actions shown while picking.
    private var selectionBar: some View {
        let picked = pickedItems
        return HStack(spacing: 22) {
            Text("\(picked.count) Selected")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if isLocal {
                Button("Move", systemImage: "folder") {
                    relocation = Relocation(items: picked, purpose: .move)
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    picked.forEach(delete)
                    selection = nil
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle") {
                    relocation = downloading(picked)
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(picked.isEmpty)
        .padding(.horizontal, 20)
        .frame(height: 52)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func createFolder() {
        let name = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        perform { try LocalSource().createFolder(named: name, in: directory) }
    }

    private func rename() {
        let name = enteredName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let item = renamedItem, !name.isEmpty, name != item.name else { return }
        if let id = item.bookmarkID {
            bookmarks.rename(id, to: name)
            return
        }
        perform { try LocalSource().rename(item, to: name) }
    }

    private func finish(_ relocation: Relocation, in folder: URL) {
        switch relocation.purpose {
        case .move:
            perform { try LocalSource().move(relocation.items, into: folder) }
        case .download:
            relocation.plan?.commit(to: folder)
        }
        selection = nil
    }

    /// Runs a file operation, then shows the listing as it now is.
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            Log.app.error("File operation failed: \(error, privacy: .public)")
            operationFailure = error.localizedDescription
        }
        reload()
    }

    private func edit(_ item: BrowserItem) {
        guard let (serverID, _) = MediaServer.parse(item.url) else { return }
        editedServer = servers.server(serverID)
    }

    private func canDelete(_ item: BrowserItem) -> Bool {
        item.kind == .server || item.kind == .bookmark || source.supportsDeletion
    }

    private func delete(_ item: BrowserItem) {
        if let id = item.bookmarkID {
            // Only the shortcut goes; the folder it led to is untouched.
            bookmarks.remove(id)
            return
        }
        if item.kind == .server {
            // Removing a server forgets it and its password; nothing on the server changes.
            if let (serverID, _) = MediaServer.parse(item.url) {
                servers.remove(serverID)
            }
            return
        }
        do {
            try source.delete(item)
        } catch {
            Log.app.error("Deleting \(item.name, privacy: .public) failed: \(error, privacy: .public)")
            return
        }
        items.removeAll { $0 == item }
    }
}

/// The night sky behind the browser: the flat background with a faint glow from the top.
private struct BrowserBackground: View {
    var body: some View {
        ZStack {
            Theme.background
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.11, blue: 0.24), .clear],
                startPoint: .top,
                endPoint: UnitPoint(x: 0.5, y: 0.55)
            )
            // Moonlight from the top trailing corner.
            RadialGradient(
                colors: [Theme.accent.opacity(0.10), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}
