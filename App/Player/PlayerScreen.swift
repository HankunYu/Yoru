import SwiftUI

/// SwiftUI entry point to the UIKit player.
struct PlayerScreen: UIViewControllerRepresentable {
    let target: PlaybackTarget
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> PlayerViewController {
        let controller = PlayerViewController(location: target.location)
        controller.onClose = onClose
        return controller
    }

    func updateUIViewController(_ controller: PlayerViewController, context: Context) {
        controller.onClose = onClose
    }
}
