import Foundation
import Observation

/// One audio, video or subtitle track of the current file.
struct MediaTrack: Identifiable, Equatable {
    enum Kind: String {
        case video
        case audio
        case sub
    }

    let id: Int
    let kind: Kind
    let title: String?
    let language: String?
    let codec: String?
    let isSelected: Bool

    var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty { parts.append(language.uppercased()) }
        if parts.isEmpty { parts.append(String(localized: "Track \(id)")) }
        if let codec, !codec.isEmpty { parts.append(codec) }
        return parts.joined(separator: " · ")
    }
}

/// A transient on-screen message, shown as a small pill.
struct OSDMessage: Equatable {
    var symbol: String
    var text: String
    /// 0...1 level shown as a bar (volume, brightness); nil for text-only messages.
    var level: Double?
}

/// Observable playback state and intents for the player UI.
///
/// Mirrors mpv properties (the single source of truth) and turns UI intents into mpv
/// commands. All mpv calls are asynchronous; see `MPVPlayer`.
@MainActor
@Observable
final class PlayerModel {
    // MARK: State mirrored from mpv

    private(set) var title = ""
    private(set) var isPaused = false
    private(set) var isBuffering = false
    private(set) var isIdle = true
    private(set) var duration: Double = 0
    private(set) var speed: Double = 1
    private(set) var tracks: [MediaTrack] = []
    /// Playback position; while the seek bar is dragged this is the drag position.
    private(set) var position: Double = 0
    /// Position at the last discontinuity (seek, pause, rate change). Observers that only
    /// need a reference point (lock screen) read this instead of the per-frame `position`.
    private(set) var nowPlayingReferencePosition: Double = 0

    // MARK: Interface state

    private(set) var controlsVisible = true
    /// The controls have their own half of a half-folded display: they stay visible, since
    /// they cover no picture.
    private(set) var hasDedicatedControlArea = false
    private(set) var osd: OSDMessage?
    var showsDiagnostics = false
    /// Raw string values of observed diagnostic properties.
    private(set) var diagnostics: [String: String] = [:]
    private(set) var errorMessage: String?

    /// Called for `script-message yoru brightness <delta>`; returns the new 0...1 level.
    var adjustBrightness: ((Double) -> Double)?
    /// Called for `script-message yoru volume <delta>`; the new level arrives through
    /// `systemVolumeDidChange`.
    var adjustSystemVolume: ((Double) -> Void)?
    var onClose: (() -> Void)?

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    static let diagnosticProperties = [
        "hwdec-current",
        "video-params/gamma",
        "video-params/sig-peak",
        "video-out-params/w",
        "video-out-params/h",
        "estimated-vf-fps",
        "frame-drop-count",
        "decoder-frame-drop-count",
        "video-bitrate",
    ]

    private var player: MPVPlayer?
    private let options = YoruOptions.load()
    private var isScrubbing = false
    private var seekInFlight = false
    private var pendingSeek: (target: Double, exact: Bool)?
    private var seekFlushTask: Task<Void, Never>?
    // Whether the current scrub paused playback and must resume it when it ends.
    private var resumesAfterScrub = false
    // Position when a swipe scrub began; the swipe seeks relative to it.
    private var swipeOrigin: Double = 0
    // Speed to return to when a `hold-speed` ends; nil when no hold is active.
    private var speedBeforeHold: Double?
    // Pending speed changes issued by a hold, whose property events must not raise an OSD.
    private var silentSpeedChanges = 0
    private var hideControlsTask: Task<Void, Never>?
    private var hideOSDTask: Task<Void, Never>?
    // Properties whose changes surface as an OSD message; the first event for each is the
    // initial value, not a change.
    private var announcedOnce: Set<String> = []

    var audioTracks: [MediaTrack] { tracks.filter { $0.kind == .audio } }
    var subtitleTracks: [MediaTrack] { tracks.filter { $0.kind == .sub } }

    // MARK: - Wiring

    func attach(_ player: MPVPlayer) {
        self.player = player
        player.observe("media-title", format: .string)
        player.observe("pause", format: .flag)
        player.observe("paused-for-cache", format: .flag)
        player.observe("idle-active", format: .flag)
        player.observe("time-pos", format: .double)
        player.observe("duration", format: .double)
        player.observe("speed", format: .double)
        player.observe("volume", format: .double)
        player.observe("video-zoom", format: .double)
        player.observe("track-list", format: .node)
        for name in Self.diagnosticProperties {
            player.observe(name, format: .string)
        }
        scheduleControlsHide()
    }

    func detach() {
        hideControlsTask?.cancel()
        hideOSDTask?.cancel()
        seekFlushTask?.cancel()
        player = nil
    }

    func report(error: String) {
        errorMessage = error
    }

    func handle(_ event: MPVEvent) {
        switch event {
        case .propertyChanged(let name, let value):
            handleProperty(name, value)
        case .clientMessage(let arguments):
            handleMessage(arguments)
        case .playbackRestart:
            // Fires after every seek and at start.
            nowPlayingReferencePosition = position
            seekDidComplete()
        case .fileLoaded, .endFile, .videoReconfig, .log, .shutdown:
            break
        }
    }

    // MARK: - Intents

    func togglePause() {
        player?.command("cycle", "pause")
        keepControlsVisible()
    }

    func pauseIfPlaying() {
        if !isPaused {
            player?.setProperty("pause", "yes")
        }
    }

    func skip(_ seconds: Double) {
        player?.command("seek", String(seconds), "relative")
        keepControlsVisible()
    }

    /// Seek bar drag. Follows `seekbar-keyframes`: fast keyframe seeks while dragging.
    func scrub(to newPosition: Double) {
        scrub(to: newPosition, exact: !options.seekbarKeyframes)
    }

    private func scrub(to newPosition: Double, exact: Bool) {
        if !isScrubbing {
            // Hold the picture still while scrubbing; playback resumes on release.
            resumesAfterScrub = !isPaused
            if resumesAfterScrub {
                player?.setProperty("pause", "yes")
            }
        }
        isScrubbing = true
        position = newPosition
        hideControlsTask?.cancel()
        requestSeek(to: newPosition, exact: exact)
    }

    /// Horizontal swipe on the video: scrubs relative to where the swipe began, at
    /// `swipe-seek-rate` seconds per point. Always frame-exact: a swipe is for fine
    /// positioning, and seek pacing keeps exact seeks fluid.
    func handle(_ scrub: TouchInput.Scrub) {
        switch scrub {
        case .began:
            swipeOrigin = position
        case .moved(let points):
            guard duration > 0 else { return }
            let target = min(max(swipeOrigin + Double(points) * options.swipeSeekRate, 0), duration)
            self.scrub(to: target, exact: true)
            let delta = target - swipeOrigin
            let sign = delta < 0 ? "−" : "+"
            show(OSDMessage(
                symbol: delta < 0 ? "backward.fill" : "forward.fill",
                text: "\(Self.format(time: target))  \(sign)\(Self.format(time: abs(delta)))"
            ))
        case .ended:
            endScrub()
        }
    }

    func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        requestSeek(to: position, exact: true)
        if resumesAfterScrub {
            resumesAfterScrub = false
            player?.setProperty("pause", "no")
        }
        scheduleControlsHide()
    }

    func select(_ track: MediaTrack?, kind: MediaTrack.Kind) {
        let property = switch kind {
        case .video: "vid"
        case .audio: "aid"
        case .sub: "sid"
        }
        player?.setProperty(property, track.map { String($0.id) } ?? "no")
    }

    func setSpeed(_ newSpeed: Double) {
        player?.setProperty("speed", String(newSpeed))
    }

    /// Toggles mpv's built-in stats overlay (a Lua script).
    func toggleStats() {
        player?.command("script-binding", "stats/display-stats-toggle")
    }

    func close() {
        onClose?()
    }

    private func beginHoldSpeed(_ holdSpeed: Double) {
        guard speedBeforeHold == nil else { return }
        speedBeforeHold = speed
        setSpeedSilently(holdSpeed)
        show(OSDMessage(symbol: "forward.fill", text: Self.format(speed: holdSpeed)), sticky: true)
    }

    /// The finger lifted after a long press: undo a running `hold-speed`.
    func endHoldSpeed() {
        guard let previous = speedBeforeHold else { return }
        speedBeforeHold = nil
        setSpeedSilently(previous)
        osd = nil
    }

    private func setSpeedSilently(_ newSpeed: Double) {
        // mpv reports no change event when the value stays the same.
        guard abs(newSpeed - speed) > 0.0001 else { return }
        silentSpeedChanges += 1
        player?.setProperty("speed", String(newSpeed))
    }

    /// The system volume changed (gesture or hardware buttons).
    func systemVolumeDidChange(_ level: Double) {
        show(OSDMessage(
            symbol: level <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
            text: "\(Int((level * 100).rounded()))%",
            level: level
        ))
    }

    func toggleControls() {
        guard !hasDedicatedControlArea else { return }
        controlsVisible ? hideControls() : keepControlsVisible()
    }

    func setDedicatedControlArea(_ dedicated: Bool) {
        guard dedicated != hasDedicatedControlArea else { return }
        hasDedicatedControlArea = dedicated
        keepControlsVisible()
    }

    /// Shows the controls and restarts the auto-hide timer.
    func keepControlsVisible() {
        controlsVisible = true
        scheduleControlsHide()
    }

    // MARK: - Seek pacing

    /// Sends a scrub seek, but never while the previous one is still being decoded.
    ///
    /// mpv aborts an in-progress seek when a new one arrives. A finger moving faster than
    /// seeks complete would therefore keep cancelling them and the picture would freeze
    /// until it stops. Waiting for `playback-restart` and then sending only the newest
    /// target shows every frame the decoder can actually deliver.
    private func requestSeek(to target: Double, exact: Bool) {
        if seekInFlight {
            pendingSeek = (target, exact)
            // Safety net in case mpv never reports the restart (e.g. seeking at end of file).
            seekFlushTask?.cancel()
            seekFlushTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                self?.seekDidComplete()
            }
        } else {
            seekInFlight = true
            player?.command("seek", String(target), exact ? "absolute+exact" : "absolute+keyframes")
        }
    }

    private func seekDidComplete() {
        seekFlushTask?.cancel()
        seekInFlight = false
        if let (target, exact) = pendingSeek {
            pendingSeek = nil
            requestSeek(to: target, exact: exact)
        }
    }

    // MARK: - mpv events

    private func handleProperty(_ name: String, _ value: MPVValue) {
        switch name {
        case "media-title":
            title = value.stringValue ?? ""
        case "pause":
            isPaused = value.flagValue ?? false
            nowPlayingReferencePosition = position
            // Paused playback keeps the controls up; resuming starts the timer again.
            scheduleControlsHide()
        case "paused-for-cache":
            isBuffering = value.flagValue ?? false
        case "idle-active":
            isIdle = value.flagValue ?? true
        case "time-pos":
            guard !isScrubbing, let newPosition = value.doubleValue else { return }
            position = newPosition
            if osd?.symbol == Self.positionSymbol {
                osd?.text = positionText
            }
        case "duration":
            duration = value.doubleValue ?? 0
        case "speed":
            speed = value.doubleValue ?? 1
            nowPlayingReferencePosition = position
            // Changes made by a hold are announced by the hold itself.
            if silentSpeedChanges > 0 {
                silentSpeedChanges -= 1
                return
            }
            announce(name) {
                OSDMessage(symbol: "gauge.with.dots.needle.50percent", text: Self.format(speed: speed))
            }
        case "volume":
            let volume = value.doubleValue ?? 100
            announce(name) {
                OSDMessage(
                    symbol: volume <= 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    text: "\(Int(volume.rounded()))%",
                    level: min(volume / 100, 1)
                )
            }
        case "video-zoom":
            let zoom = value.doubleValue ?? 0
            announce(name) {
                OSDMessage(symbol: "plus.magnifyingglass", text: String(format: "%.0f%%", pow(2, zoom) * 100))
            }
        case "track-list":
            tracks = (value.arrayValue ?? []).compactMap(MediaTrack.init)
        default:
            diagnostics[name] = value.stringValue ?? "-"
        }
    }

    private func handleMessage(_ arguments: [String]) {
        guard arguments.first == "yoru", arguments.count >= 2 else { return }
        switch arguments[1] {
        case "toggle-controls":
            toggleControls()
        case "show-position":
            show(OSDMessage(symbol: Self.positionSymbol, text: positionText))
        case "hold-speed":
            guard arguments.count >= 3, let holdSpeed = Double(arguments[2]), holdSpeed > 0 else { return }
            beginHoldSpeed(holdSpeed)
        case "volume":
            guard arguments.count >= 3, let delta = Double(arguments[2]) else { return }
            adjustSystemVolume?(delta)
        case "brightness":
            guard arguments.count >= 3, let delta = Double(arguments[2]), let level = adjustBrightness?(delta) else {
                return
            }
            show(OSDMessage(symbol: "sun.max.fill", text: "\(Int((level * 100).rounded()))%", level: level))
        default:
            Log.player.warning("Unknown yoru message: \(arguments[1], privacy: .public)")
        }
    }

    // MARK: - OSD and auto-hide

    private static let positionSymbol = "clock"

    private var positionText: String {
        "\(Self.format(time: position)) / \(Self.format(time: duration))"
    }

    private func announce(_ property: String, _ message: () -> OSDMessage) {
        guard announcedOnce.contains(property) else {
            announcedOnce.insert(property)
            return
        }
        show(message())
    }

    /// - Parameter sticky: Keep the message up until it is replaced or cleared.
    private func show(_ message: OSDMessage, sticky: Bool = false) {
        osd = message
        hideOSDTask?.cancel()
        guard !sticky else { return }
        hideOSDTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.osd = nil
        }
    }

    private func hideControls() {
        hideControlsTask?.cancel()
        controlsVisible = false
    }

    private func scheduleControlsHide() {
        hideControlsTask?.cancel()
        guard controlsVisible, !isPaused, !isScrubbing, !hasDedicatedControlArea else { return }
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    // MARK: - Formatting

    static func format(time seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(seconds, 0) : 0)
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    static func format(speed: Double) -> String {
        speed == speed.rounded() ? String(format: "%.0f×", speed) : String(format: "%g×", speed)
    }
}

private extension MediaTrack {
    init?(_ value: MPVValue) {
        guard let id = value["id"]?.intValue,
              let kind = value["type"]?.stringValue.flatMap(Kind.init(rawValue:)) else {
            return nil
        }
        self.init(
            id: id,
            kind: kind,
            title: value["title"]?.stringValue,
            language: value["lang"]?.stringValue,
            codec: value["codec"]?.stringValue,
            isSelected: value["selected"]?.flagValue ?? false
        )
    }
}
