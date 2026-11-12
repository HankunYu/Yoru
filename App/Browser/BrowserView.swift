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
    @State private var importer = FileImporter()
    @State private var isShowingSettings = false
    @State private var isAddingServer = false
    // App UI state, not mpv configuration, so it lives in UserDefaults.
    @AppStorage("browser.viewMode") private var viewMode = BrowserViewMode.grid
    @AppStorage("browser.sortOrder") private var sortOrder = BrowserSortOrder.name
    private let servers = ServerStore.shared

    private var source: any MediaSource { MediaSources.source(for: directory) }
    private var isRoot: Bool { directory == URL.documentsDirectory }
    private var isLocal: Bool { directory.isFileURL }

    private var title: String {
        if isRoot { return "YORU" }
        if let (serverID, path) = SMBSource.parse(directory), path.isEmpty {
            return servers.server(serverID)?.name ?? ""
        }
        return directory.lastPathComponent
    }

    var body: some View {
        BrowserList(items: items, mode: viewMode, canDelete: canDelete, onSelect: open, onDelete: delete)
            .ignoresSafeArea()
            .background { BrowserBackground() }
        .overlay(alignment: .bottom) {
            if let progress = importer.progress {
                ImportProgressBar(progress: progress, onCancel: importer.cancel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: importer.isImporting)
        .alert("Import Failed", isPresented: Binding(
            get: { importer.errorMessage != nil },
            set: { if !$0 { importer.dismissError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importer.errorMessage ?? "")
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
            } else if items.isEmpty, isLocal {
                ContentUnavailableView {
                    Label("No Files", systemImage: "moon.stars")
                } description: {
                    Text("Copy videos into YORU with the Files app, or import them here.")
                } actions: {
                    Button("Import") { isImporting = true }
                        .buttonStyle(.glass)
                        .disabled(importer.isImporting)
                }
            } else if items.isEmpty {
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu("More", systemImage: "ellipsis") {
                    Picker("View", selection: $viewMode) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(BrowserViewMode.grid)
                        Label("List", systemImage: "list.bullet").tag(BrowserViewMode.list)
                    }
                    .pickerStyle(.inline)
                    Picker("Sort By", selection: $sortOrder) {
                        Label("Name", systemImage: "textformat").tag(BrowserSortOrder.name)
                        Label("Date", systemImage: "calendar").tag(BrowserSortOrder.date)
                        Label("Size", systemImage: "internaldrive").tag(BrowserSortOrder.size)
                    }
                    .pickerStyle(.inline)
                }
                if isRoot {
                    Button("Add Server", systemImage: "server.rack") { isAddingServer = true }
                }
                Button("Open Location", systemImage: "link") { isEnteringLocation = true }
                if isLocal {
                    Button("Import", systemImage: "plus") { isImporting = true }
                        .disabled(importer.isImporting)
                }
            }
        }
        .sheet(isPresented: $isAddingServer) {
            AddServerView()
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
        importer.start(urls, into: directory) { reload() }
    }

    private func open(_ item: BrowserItem) {
        if item.isDirectory {
            path.append(item)
        } else if item.mediaKind.isPlayable {
            playing = PlaybackTarget(item: item, siblings: items)
        }
    }

    private func canDelete(_ item: BrowserItem) -> Bool {
        item.kind == .server || source.supportsDeletion
    }

    private func delete(_ item: BrowserItem) {
        if item.kind == .server {
            // Removing a server forgets it and its password; nothing on the server changes.
            if let (serverID, _) = SMBSource.parse(item.url) {
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
        items.removeAll { $0.id == item.id }
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

/// Bottom bar shown while files are being imported.
private struct ImportProgressBar: View {
    let progress: FileImporter.Progress
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
            Button("Cancel Import", systemImage: "xmark.circle.fill", action: onCancel)
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
        return "\(position)\(copied) / \(total)"
    }
}
