import SwiftUI

/// SwiftUI entry point to the UIKit player.
struct PlayerScreen: UIViewControllerRepresentable {
    let target: PlaybackTarget
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> PlayerViewController {
        PlayerViewController(location: target.location, onClose: onClose)
    }

    func updateUIViewController(_ controller: PlayerViewController, context: Context) {}
}
