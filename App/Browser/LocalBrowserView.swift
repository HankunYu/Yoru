import SwiftUI
import UniformTypeIdentifiers

/// One entry in a browsed directory.
struct BrowserItem: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Lists a directory of the app's Documents folder (M0: local files only).
struct LocalBrowserView: View {
    let directory: URL
    @Binding var playing: PlaybackTarget?

    @State private var items: [BrowserItem] = []
    @State private var isImporting = false
    @State private var isEnteringLocation = false
    @State private var enteredLocation = ""

    var body: some View {
        List(items) { item in
            if item.isDirectory {
                NavigationLink(value: item) {
                    Label(item.name, systemImage: "folder")
                }
            } else {
                Button {
                    playing = PlaybackTarget(fileURL: item.url)
                } label: {
                    Label(item.name, systemImage: "film")
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Files",
                    systemImage: "tray",
                    description: Text("Copy videos into Yoru with the Files app, or import them here.")
                )
            }
        }
        .navigationTitle(directory == URL.documentsDirectory ? "Yoru" : directory.lastPathComponent)
        .toolbar {
            Button("Open Location", systemImage: "link") { isEnteringLocation = true }
            Button("Import", systemImage: "plus") { isImporting = true }
        }
        .alert("Open Location", isPresented: $isEnteringLocation) {
            TextField("smb://user:pass@host/share/file.mkv", text: $enteredLocation)
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
            Text("Any URL mpv can open: smb, http(s), dav(s).")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .refreshable { reload() }
        .onAppear { reload() }
    }

    private func reload() {
        let fileManager = FileManager.default
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        items = urls
            // The mpv config directory is managed through the Files app, not played from.
            .filter { $0.standardizedFileURL != ConfigDirectory.url.standardizedFileURL }
            .map { url in
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return BrowserItem(url: url, isDirectory: isDirectory)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let destination = directory.appending(path: url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
            } catch {
                Log.app.error("Import failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
        reload()
    }
}
