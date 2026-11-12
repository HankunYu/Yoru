import AVFoundation
import MediaPlayer

/// Lock screen / Control Center integration and audio session events for one playback.
@MainActor
final class NowPlayingSession {
    private let model: PlayerModel
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []

    init(model: PlayerModel) {
        self.model = model
        registerCommands()
        observeAudioSession()
        trackModel()
    }

    func invalidate() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.playCommand) { model, _ in if model.isPaused { model.togglePause() } }
        add(center.pauseCommand) { model, _ in if !model.isPaused { model.togglePause() } }
        add(center.togglePlayPauseCommand) { model, _ in model.togglePause() }
        center.skipForwardCommand.preferredIntervals = [10]
        add(center.skipForwardCommand) { model, _ in model.skip(10) }
        center.skipBackwardCommand.preferredIntervals = [10]
        add(center.skipBackwardCommand) { model, _ in model.skip(-10) }
        add(center.changePlaybackPositionCommand) { model, event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
            model.scrub(to: event.positionTime)
            model.endScrub()
        }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (PlayerModel, MPRemoteCommandEvent) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { [weak model] event in
            guard let model else { return .commandFailed }
            MainActor.assumeIsolated { action(model, event) }
            return .success
        }
        commandTargets.append((command, target))
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        // A phone call or another app taking the audio session pauses playback; it is not
        // resumed automatically.
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak model] notification in
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            MainActor.assumeIsolated { model?.pauseIfPlaying() }
        })
        // Unplugging headphones must not continue on the speaker.
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak model] notification in
            let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            MainActor.assumeIsolated { model?.pauseIfPlaying() }
        })
    }

    /// Republishes now-playing info whenever the fields it depends on change. The elapsed
    /// time is only a reference point: the system extrapolates from the playback rate.
    private func trackModel() {
        withObservationTracking {
            publish()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackModel() }
        }
    }

    private func publish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: model.title,
            MPMediaItemPropertyPlaybackDuration: model.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.nowPlayingReferencePosition,
            MPNowPlayingInfoPropertyPlaybackRate: model.isPaused ? 0 : model.speed,
        ]
    }
}
