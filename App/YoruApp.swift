import AVFoundation
import SwiftUI

@main
struct YoruApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate

    init() {
        ConfigDirectory.prepare()
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
