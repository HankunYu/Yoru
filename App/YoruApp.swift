import AVFoundation
import SwiftUI

@main
struct YoruApp: App {
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

    var body: some View {
        NavigationStack {
            LocalBrowserView(directory: .documentsDirectory, playing: $playing)
                .navigationDestination(for: BrowserItem.self) { item in
                    LocalBrowserView(directory: item.url, playing: $playing)
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
