import AVFoundation
import SwiftUI

@main
struct YoruApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        // Writing to a socket the other end has closed raises SIGPIPE, which by default
        // kills the process. libsmbclient writes to its sockets without guarding against
        // it, and a server dropping an idle connection is routine; the write then fails
        // with EPIPE instead, which is handled like any other error.
        signal(SIGPIPE, SIG_IGN)
        ConfigDirectory.prepare()
        // The container directory is named by its ID; skip anything that does not look like one.
        let containerID = URL.homeDirectory.lastPathComponent
        if UUID(uuidString: containerID) != nil {
            ResumePositions.rebase(
                in: ConfigDirectory.url.appending(path: "watch_later", directoryHint: .isDirectory),
                containerID: containerID
            )
        }
        do {
            // Playback category keeps audio going with the screen locked or the app in the background.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        } catch {
            Log.app.error("Audio session setup failed: \(error, privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @State private var playing: PlaybackTarget?
    @State private var path: [BrowserItem] = []

    var body: some View {
        NavigationStack(path: $path) {
            BrowserView(directory: .documentsDirectory, playing: $playing, path: $path)
                .navigationDestination(for: BrowserItem.self) { item in
                    BrowserView(directory: item.url, playing: $playing, path: $path)
                }
        }
        // Files opened from other apps (Files, share sheet) arrive here and play in place.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            playing?.endAccess()
            playing = PlaybackTarget(openedInPlace: url)
        }
        .fullScreenCover(item: $playing, onDismiss: nil) { target in
            PlayerScreen(target: target) {
                target.endAccess()
                playing = nil
            }
                .ignoresSafeArea()
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
        }
    }
}
