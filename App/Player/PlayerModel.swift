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
    /// Loaded from a separate file; its `title` is then that file's name.
    let isExternal: Bool

    var displayName: String {
        var parts: [String] = []
        if let title, !title.isEmpty { parts.append(title) }
        if let language, !language.isEmpty { parts.append(language.uppercased()) }
        if parts.isEmpty { parts.append(String(localized: "Track \(id)")) }
        if let codec, !codec.isEmpty { parts.append(codec) }
        return parts.joined(separator: " · ")
    }
}

/// A numeric mpv property the adjustments panel reads and writes.
enum PlayerNumber: String, CaseIterable {
    case subtitleDelay = "sub-delay"
    case audioDelay = "audio-delay"
    case subtitleScale = "sub-scale"
    case subtitlePosition = "sub-pos"
    case volume
    case brightness
    case contrast
    case saturation
    case gamma
    case rotation = "video-rotate"
    case panscan
    case aspectOverride = "video-aspect-override"
    /// Unset unless an A-B loop point has been placed.
    case loopStart = "ab-loop-a"
    case loopEnd = "ab-loop-b"

    /// The value mpv starts with, shown until the first property event arrives.
    var defaultValue: Double {
        switch self {
        case .subtitleScale: 1
        case .subtitlePosition, .volume: 100
        case .aspectOverride: -1
        default: 0
        }
    }
}

/// A boolean mpv property the adjustments panel reads and writes.
enum PlayerFlag: String, CaseIterable {
    case subtitlesVisible = "sub-visibility"
    case deband
    case keepsAspect = "keepaspect"

    var defaultValue: Bool {
        switch self {
        case .subtitlesVisible, .keepsAspect: true
        case .deband: false
        }
    }
}

/// How the picture is fitted to the screen.
enum AspectMode: CaseIterable {
    /// The whole picture, with bars where the shapes differ.
    case fit
    /// Fills the screen, cropping the picture.
    case fill
    /// Fills the screen, distorting the picture.
    case stretch
    case wide
    case standard
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
    /// A file is being opened and has not shown its first frame yet.
    private(set) var isLoading = false
    /// Bytes per second mpv's cache is reading from the source.
    private var cacheSpeed: Int = 0
    /// Bytes per second read through app-served streams, measured while waiting.
    private var streamSpeed: Int = 0
    private var speedSamplingTask: Task<Void, Never>?

    /// Whether the picture is waiting for data: opening a file, or refilling the cache.
    var isWaiting: Bool { isLoading || isBuffering }
    /// The rate data is arriving at while waiting; 0 when unknown.
    var transferSpeed: Int { max(cacheSpeed, streamSpeed) }
    /// Whether a rate is worth showing for the current wait: there is one from mpv's cache,
    /// or app-served streams have delivered something. Once shown it stays, reading zero
    /// during a stall rather than vanishing.
    var showsTransferSpeed: Bool { isBuffering || hasMeasuredStreamSpeed }
    private var hasMeasuredStreamSpeed = false
    /// The time up to which the file is buffered ahead of the playback position.
    private(set) var bufferedEnd: Double = 0
    private(set) var isIdle = true
    /// Playback stopped on the last frame of the file.
    private(set) var hasReachedEnd = false
    /// Whether the folder has a file before / after the current one.
    var hasPrevious = false
    var hasNext = false
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
    /// The adjustments panel is open, in place of the regular controls.
    private(set) var showsAdjustments = false
    /// The adjustments panel rises from the bottom rather than sliding in from the side;
    /// it then shows a grabber to drag it away by. Set by whoever lays the panel out.
    var adjustmentsRiseFromBottom = false
    private var numbers: [PlayerNumber: Double] = [:]
    private var flags: [PlayerFlag: Bool] = [:]
    /// The second subtitle track shown above the main one, if any.
    private(set) var secondarySubtitleID: Int?
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
    /// Moves to the neighboring file of the folder: -1 for the previous, 1 for the next.
    var onStep: ((Int) -> Void)?
    var onReachedEnd: (() -> Void)?
    /// Set before loading to have the starting subtitle picked once the file is loaded.
    var initialSubtitleChoice: PlaybackTarget.InitialSubtitleChoice?
    // The file is loaded and the choice waits for the track list that reflects mpv's own.
    private var awaitsInitialSubtitleChoice = false

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
        player.observe("cache-speed", format: .int)
        player.observe("demuxer-cache-time", format: .double)
        player.observe("idle-active", format: .flag)
        player.observe("eof-reached", format: .flag)
        player.observe("time-pos", format: .double)
        player.observe("duration", format: .double)
        player.observe("speed", format: .double)
        player.observe("volume", format: .double)
        player.observe("video-zoom", format: .double)
        player.observe("track-list", format: .node)
        for number in PlayerNumber.allCases where number != .volume {
            player.observe(number.rawValue, format: .double)
        }
        for flag in PlayerFlag.allCases {
            player.observe(flag.rawValue, format: .flag)
        }
        player.observe("secondary-sid", format: .string)
        for name in Self.diagnosticProperties {
            player.observe(name, format: .string)
        }
        scheduleControlsHide()
    }

    /// Called when a file starts opening.
    func beginLoading() {
        isLoading = true
        updateSpeedSampling()
    }

    /// Whether the position is at the end or in the last stretch of the file (credits):
    /// close enough that resuming there would be pointless, so it counts as finished.
    var isNearEnd: Bool {
        if hasReachedEnd { return true }
        guard duration > 0 else { return false }
        let tail = min(max(duration * 0.05, 10), 180)
        return position >= duration - tail
    }

    /// Samples the app-served streams twice a second for as long as the picture waits.
    private func updateSpeedSampling() {
        guard isWaiting else {
            speedSamplingTask?.cancel()
            speedSamplingTask = nil
            streamSpeed = 0
            hasMeasuredStreamSpeed = false
            return
        }
        guard speedSamplingTask == nil else { return }
        speedSamplingTask = Task { [weak self] in
            var last = MPVStreamMeter.bytesRead
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                let now = MPVStreamMeter.bytesRead
                guard let self else { return }
                // Averaged with the previous reading: opening a file reads in bursts, and
                // raw half-second samples jump between a real rate and zero.
                let sample = Int(now - last) * 2
                streamSpeed = hasMeasuredStreamSpeed ? (streamSpeed + sample) / 2 : sample
                if sample > 0 {
                    hasMeasuredStreamSpeed = true
                }
                last = now
            }
        }
    }

    func detach() {
        speedSamplingTask?.cancel()
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
            isLoading = false
            updateSpeedSampling()
            nowPlayingReferencePosition = position
            seekDidComplete()
        case .fileLoaded:
            // mpv has made its own selection by now; the track list reporting it is still
            // on its way, so the choice is made when that arrives.
            awaitsInitialSubtitleChoice = initialSubtitleChoice != nil
        case .endFile:
            // Covers a file that failed to open; a new one sets it again.
            isLoading = false
            updateSpeedSampling()
        case .videoReconfig, .log, .shutdown:
            break
        }
    }

    private func chooseInitialSubtitle() {
        guard awaitsInitialSubtitleChoice, let choice = initialSubtitleChoice else { return }
        awaitsInitialSubtitleChoice = false
        initialSubtitleChoice = nil
        let candidates = subtitleTracks.map { track in
            SubtitleChooser.Candidate(
                id: track.id,
                isSelected: track.isSelected,
                language: track.language,
                externalName: track.isExternal ? track.title : nil
            )
        }
        if let id = SubtitleChooser.choice(among: candidates, codes: choice.codes, stem: choice.stem) {
            player?.setProperty("sid", String(id))
        }
    }

    // MARK: - Intents

    func togglePause() {
        player?.command("cycle", "pause")
        keepControlsVisible()
    }

    func step(_ offset: Int) {
        onStep?(offset)
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

    // MARK: - Adjustments

    func number(_ number: PlayerNumber) -> Double {
        numbers[number] ?? number.defaultValue
    }

    /// Whether mpv reports a value at all; false for an A-B loop point that is not placed.
    func isSet(_ number: PlayerNumber) -> Bool {
        numbers[number] != nil
    }

    func set(_ number: PlayerNumber, to value: Double) {
        // Shown at once rather than when mpv echoes it, so a dragged slider does not lag.
        numbers[number] = value
        player?.setProperty(number.rawValue, String(value))
    }

    func clear(_ number: PlayerNumber) {
        numbers[number] = nil
        player?.setProperty(number.rawValue, "no")
    }

    func flag(_ flag: PlayerFlag) -> Bool {
        flags[flag] ?? flag.defaultValue
    }

    func set(_ flag: PlayerFlag, to value: Bool) {
        flags[flag] = value
        player?.setProperty(flag.rawValue, value ? "yes" : "no")
    }

    func selectSecondarySubtitle(_ track: MediaTrack?) {
        secondarySubtitleID = track?.id
        player?.setProperty("secondary-sid", track.map { String($0.id) } ?? "no")
    }

    var aspectMode: AspectMode {
        if !flag(.keepsAspect) { return .stretch }
        let override = number(.aspectOverride)
        if abs(override - 16.0 / 9) < 0.01 { return .wide }
        if abs(override - 4.0 / 3) < 0.01 { return .standard }
        return number(.panscan) >= 1 ? .fill : .fit
    }

    func setAspectMode(_ mode: AspectMode) {
        set(.keepsAspect, to: mode != .stretch)
        set(.panscan, to: mode == .fill ? 1 : 0)
        switch mode {
        case .wide: set(.aspectOverride, to: 16.0 / 9)
        case .standard: set(.aspectOverride, to: 4.0 / 3)
        default: set(.aspectOverride, to: -1)
        }
    }

    func showAdjustments() {
        showsAdjustments = true
    }

    func hideAdjustments() {
        guard showsAdjustments else { return }
        showsAdjustments = false
        keepControlsVisible()
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
        // A tap on the picture dismisses the adjustments panel first.
        if showsAdjustments {
            hideAdjustments()
            return
        }
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
            updateSpeedSampling()
        case "cache-speed":
            cacheSpeed = value.intValue ?? 0
        case "demuxer-cache-time":
            bufferedEnd = value.doubleValue ?? 0
        case "eof-reached":
            let reached = value.flagValue ?? false
            guard reached != hasReachedEnd else { return }
            hasReachedEnd = reached
            if reached {
                onReachedEnd?()
            }
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
            numbers[.volume] = volume
            // The panel's own slider already shows the value.
            guard !showsAdjustments else { return }
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
            chooseInitialSubtitle()
        case "secondary-sid":
            secondarySubtitleID = value.stringValue.flatMap(Int.init)
        default:
            if let number = PlayerNumber(rawValue: name) {
                numbers[number] = value.doubleValue
            } else if let flag = PlayerFlag(rawValue: name) {
                flags[flag] = value.flagValue
            } else {
                diagnostics[name] = value.stringValue ?? "-"
            }
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
            isSelected: value["selected"]?.flagValue ?? false,
            isExternal: value["external"]?.flagValue ?? false
        )
    }
}
