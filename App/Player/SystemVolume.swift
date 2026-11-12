import AVFoundation
import MediaPlayer
import UIKit

/// Reads and sets the system output volume.
///
/// iOS has no public API to set the volume; `AVAudioSession.outputVolume` is read-only.
/// The only route is the slider inside an `MPVolumeView`, so one is kept in the view
/// hierarchy (invisible) and its slider is driven programmatically. That relies on
/// `MPVolumeView` containing a `UISlider`, which is undocumented; if a future iOS changes
/// it, `adjust(by:)` degrades to a no-op rather than failing.
///
/// As a side effect, an `MPVolumeView` in the hierarchy suppresses the system volume HUD,
/// so `onChange` also fires for the hardware buttons and the player shows its own OSD.
@MainActor
final class SystemVolume {
    /// Called with the new 0...1 level whenever the system volume changes, whatever the source.
    var onChange: ((Double) -> Void)?

    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 40))
    private var observation: NSKeyValueObservation?
    // Level requested but not yet reported back, so rapid steps accumulate.
    private var pendingLevel: Float?

    init(hostView: UIView) {
        // Must be in the hierarchy and not hidden to work; it sits far off screen.
        volumeView.alpha = 0.01
        volumeView.isUserInteractionEnabled = false
        hostView.addSubview(volumeView)

        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let level = change.newValue else { return }
            Task { @MainActor in
                self?.pendingLevel = nil
                self?.onChange?(Double(level))
            }
        }
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
        volumeView.removeFromSuperview()
    }

    func adjust(by delta: Double) {
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else {
            Log.player.error("MPVolumeView has no slider; system volume cannot be set")
            return
        }
        let current = pendingLevel ?? AVAudioSession.sharedInstance().outputVolume
        let target = min(max(current + Float(delta), 0), 1)
        pendingLevel = target
        slider.setValue(target, animated: false)
        slider.sendActions(for: .valueChanged)
    }
}
