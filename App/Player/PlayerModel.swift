import Foundation
import Observation
import UIKit

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
    var language: String?
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
    case subtitleOutline = "sub-outline-size"
    case subtitleShadow = "sub-shadow-offset"

    /// The value mpv starts with, shown until the first property event arrives.
    var defaultValue: Double {
        switch self {
        case .subtitleScale: 1
        case .subtitlePosition, .volume: 100
        case .subtitleOutline: 3
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
    case subtitleBold = "sub-bold"

    var defaultValue: Bool {
        switch self {
        case .subtitlesVisible, .keepsAspect: true
        case .deband, .subtitleBold: false
        }
    }
}

/// A textual mpv property the adjustments panel reads and writes.
enum PlayerText: String, CaseIterable {
    /// `#AARRGGBB`.
    case subtitleColor = "sub-color"
    /// `outline-and-shadow` or `background-box`.
    case subtitleBorderStyle = "sub-border-style"
    /// How far these settings apply to subtitles that carry their own styling (ASS):
    /// `scale` leaves their look alone, `force` replaces it.
    case subtitleStyleOverride = "sub-ass-override"

    var defaultValue: String {
        switch self {
        case .subtitleColor: "#FFFFFFFF"
        case .subtitleBorderStyle: "outline-and-shadow"
        case .subtitleStyleOverride: "scale"
        }
    }
}

/// A chapter of the current file.
struct Chapter: Identifiable, Equatable {
    /// Its index, which is also what mpv's `chapter` property counts in.
    let id: Int
    let title: String
    let time: Double
}

/// One file of the folder being played through.
struct PlaylistEntry: Identifiable, Equatable {
    let id: Int
    let title: String
}

/// What the second-level panel shows.
enum SidePanelContent {
    case adjustments
    /// The playlist and the chapters: where to go, rather than how it looks.
    case contents
    /// What the file is: container, codecs, formats.
    case info
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
    /// What the panel holds; kept while it slides away.
    private(set) var sidePanelContent = SidePanelContent.adjustments
    private var texts: [PlayerText: String] = [:]
    private(set) var chapters: [Chapter] = []
    /// The chapter being played; nil before the first one or without chapters.
    private(set) var currentChapter: Int?
    /// The folder's files and which one is playing; empty for a file opened on its own.
    var playlist: [PlaylistEntry] = []
    var playlistIndex: Int?
    /// A picture of the current file for the lock screen, if one is at hand.
    var artwork: UIImage?
    var onSelectPlaylistEntry: ((Int) -> Void)?
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
    private(set) var showsStats = false
    /// Whether the menu offers the diagnostics overlay at all; a setting, off by default.
    let offersDiagnostics = YoruOptions.load().diagnostics
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
    /// Properties behind the file info panel, kept as mpv prints them.
    static let infoProperties = [
        "filename", "file-format", "file-size",
        "video-codec", "video-params/w", "video-params/h", "video-params/pixelformat",
        "video-params/primaries", "video-params/gamma", "video-params/colormatrix",
        "video-params/colorlevels", "container-fps",
        "audio-codec", "audio-params/samplerate", "audio-params/hr-channels", "audio-params/format",
        "audio-bitrate",
    ]
    /// The observed properties the diagnostics overlay lists: how playback is going, as
    /// opposed to what the file is, which the file info panel covers.
    static let shownDiagnostics = [
        "hwdec-current", "video-out-params/w", "video-out-params/h",
        "estimated-vf-fps", "frame-drop-count", "decoder-frame-drop-count",
    ]
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
        "chapters",
    ]

    private var player: MPVPlayer?
    private let options = YoruOptions.load()
    private(set) var normalizesVolume = false
    /// What the shaders folder holds, and what of it is in use.
    private(set) var shaderLibrary = ShaderLibrary(names: [])
    private(set) var activeShaders: [String] = []
    /// The group the active shaders were switched on as; nil for a selection made by hand.
    private(set) var activeGroup: String?
    private(set) var colorTable: String?
    /// The audio filter behind `normalizesVolume`. Labeled, so it is added to and taken
    /// from whatever `af` the user's mpv.conf sets without disturbing it.
    private static let normalizeFilter = "@yoru-normalize:dynaudnorm=g=5:f=250:r=0.9:p=0.5"
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
        for text in PlayerText.allCases {
            player.observe(text.rawValue, format: .string)
        }
        player.observe("secondary-sid", format: .string)
        player.observe("chapter-list", format: .node)
        player.observe("chapter", format: .int)
        for name in Self.diagnosticProperties + Self.infoProperties {
            player.observe(name, format: .string)
        }
        if options.normalizesVolume {
            normalizesVolume = true
            player.command("af", "add", Self.normalizeFilter)
        }
        shaderLibrary = ShaderLibrary.load()
        // A group that is on decides the shaders, as it reads now: it may have been
        // edited since. Without one, the selection made by hand.
        if let group = shaderLibrary.groups.first(where: { $0.file == options.shaderGroup }) {
            activeGroup = group.file
            activeShaders = shaderLibrary.existing(group.shaders)
        } else {
            activeShaders = shaderLibrary.existing(options.shaders)
        }
        // Appended one by one, after whatever mpv.conf may have set itself.
        for shader in activeShaders {
            player.command("change-list", "glsl-shaders", "append", ShaderLibrary.path(of: shader))
        }
        if let table = options.colorTable, shaderLibrary.tables.contains(table) {
            colorTable = table
            player.setProperty("lut", ShaderLibrary.path(of: table))
        }
        scheduleControlsHide()
    }

    /// Looks into the shaders folder again: files may have been added while the app ran.
    func refreshShaderLibrary() {
        shaderLibrary = ShaderLibrary.load()
    }

    /// Switches a shader of the library on or off. One switched on goes last. Remembered.
    func setShader(_ name: String, isOn: Bool) {
        guard isOn != activeShaders.contains(name) else { return }
        // Changed by hand, it is no longer the group it was.
        activeGroup = nil
        if isOn {
            activeShaders.append(name)
            player?.command("change-list", "glsl-shaders", "append", ShaderLibrary.path(of: name))
        } else {
            activeShaders.removeAll { $0 == name }
            player?.command("change-list", "glsl-shaders", "remove", ShaderLibrary.path(of: name))
        }
        rememberShaders()
    }

    /// Switches a group on, in place of whatever shaders are on, or off. Remembered.
    func setShaderGroup(_ group: ShaderLibrary.Group, isOn: Bool) {
        for shader in activeShaders {
            player?.command("change-list", "glsl-shaders", "remove", ShaderLibrary.path(of: shader))
        }
        activeShaders = isOn ? shaderLibrary.existing(group.shaders) : []
        activeGroup = isOn ? group.file : nil
        for shader in activeShaders {
            player?.command("change-list", "glsl-shaders", "append", ShaderLibrary.path(of: shader))
        }
        rememberShaders()
    }

    /// Keeps the shaders that are on, in their order, as a group of that name.
    func saveShadersAsGroup(named name: String) {
        guard !activeShaders.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let file = try? ShaderLibrary.save(activeShaders, asGroupNamed: name) else { return }
        shaderLibrary = ShaderLibrary.load()
        activeGroup = file
        rememberShaders()
    }

    func deleteShaderGroup(_ group: ShaderLibrary.Group) {
        ShaderLibrary.deleteGroup(group.file)
        if activeGroup == group.file {
            activeGroup = nil
            rememberShaders()
        }
        shaderLibrary = ShaderLibrary.load()
    }

    /// Uses a color lookup table of the library, or none. Remembered.
    func setColorTable(_ name: String?) {
        colorTable = name
        player?.setProperty("lut", name.map(ShaderLibrary.path(of:)) ?? "")
        rememberShaders()
    }

    private func rememberShaders() {
        var saved = YoruOptions.load()
        saved.shaders = activeShaders
        saved.shaderGroup = activeGroup
        saved.colorTable = colorTable
        saved.save()
    }

    /// Evens out loud and quiet passages. Remembered for later playback.
    func setNormalizesVolume(_ isOn: Bool) {
        guard isOn != normalizesVolume else { return }
        normalizesVolume = isOn
        if isOn {
            player?.command("af", "add", Self.normalizeFilter)
        } else {
            player?.command("af", "remove", "@yoru-normalize")
        }
        // Read again rather than saved from `options`: Settings may have changed the
        // file since this player opened.
        var saved = YoruOptions.load()
        saved.normalizesVolume = isOn
        saved.save()
    }

    /// Called when a file starts opening.
    func beginLoading() {
        isLoading = true
        // What was said about the previous file does not apply to this one.
        errorMessage = nil
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

    /// For a disc title: its streams' languages in playlist order, which is the order
    /// mpv lists the tracks in. Set before the title loads.
    var discLanguages: (audio: [String], subtitles: [String]) = ([], [])
    /// Whether the title is new to the user, so the language preferences pick its tracks.
    var awaitsDiscTrackChoice = false

    /// Gives a disc title's tracks the languages the clips leave out.
    private func withDiscLanguages(_ tracks: [MediaTrack]) -> [MediaTrack] {
        guard !discLanguages.audio.isEmpty || !discLanguages.subtitles.isEmpty else { return tracks }
        var counts: [MediaTrack.Kind: Int] = [:]
        return tracks.map { track in
            var track = track
            let index = counts[track.kind, default: 0]
            counts[track.kind] = index + 1
            let languages = track.kind == .audio ? discLanguages.audio : track.kind == .sub ? discLanguages.subtitles : []
            if track.language == nil, !track.isExternal, index < languages.count {
                track.language = languages[index]
            }
            return track
        }
    }

    /// On a first viewing, selects the audio and subtitle the language preferences ask
    /// for: mpv applies them itself, but before these tracks had a language.
    private func chooseDiscTracks() {
        guard awaitsDiscTrackChoice, !tracks.isEmpty else { return }
        awaitsDiscTrackChoice = false
        let options = PlayerOptions.load()
        func preferred(_ kind: MediaTrack.Kind, _ preference: LanguagePreference) -> MediaTrack? {
            let codes = preference.codes?.lowercased().split(separator: ",").map(String.init) ?? []
            let candidates = tracks.filter { $0.kind == kind && !$0.isExternal }
            for code in codes {
                if let match = candidates.first(where: { $0.language?.lowercased() == code }) { return match }
            }
            return nil
        }
        if let audio = preferred(.audio, options.audioLanguage), !audio.isSelected {
            player?.setProperty("aid", String(audio.id))
        }
        if let subtitle = preferred(.sub, options.subtitleLanguage), !subtitle.isSelected {
            player?.setProperty("sid", String(subtitle.id))
        }
    }

    /// Whether the filter that sets Dolby Vision aside is in place.
    private var ignoresDolbyVision = false

    /// Plays Dolby Vision by its base layer wherever it has one. Profiles 7 and 8 carry a
    /// picture that is complete without the enhancement: HDR10, or HLG in what iPhones
    /// record. mpv's processing of the latter comes out overexposed, and the base layer
    /// alone is what every other player shows. Profile 5 has no such picture and keeps
    /// the processing it cannot do without.
    private func applyDolbyVisionPolicy(_ tracks: [MPVValue]) {
        let video = tracks.first { $0["type"]?.stringValue == "video" && $0["selected"]?.flagValue == true }
        let profile = video?["dolby-vision-profile"]?.intValue
        let ignores = profile != nil && profile != 5
        guard ignores != ignoresDolbyVision else { return }
        ignoresDolbyVision = ignores
        if ignores {
            player?.command("vf", "add", "@yoru-dolby-vision:format=dolbyvision=no")
        } else {
            player?.command("vf", "remove", "@yoru-dolby-vision")
        }
    }

    /// Stops a video that would take more memory than the app is allowed, before its
    /// decoder has filled up; see `PlaybackMemory`. Stills are a single frame.
    private func declineIfTooLarge(_ tracks: [MPVValue]) {
        guard let video = tracks.first(where: {
            $0["type"]?.stringValue == "video" && $0["selected"]?.flagValue == true && $0["image"]?.flagValue != true
        }), let width = video["demux-w"]?.intValue, let height = video["demux-h"]?.intValue else { return }
        let format = video["format-name"]?.stringValue
        guard !PlaybackMemory.fits(width: width, height: height, pixelFormat: format, limit: PlaybackMemory.limit) else { return }
        player?.command("stop")
        isLoading = false
        report(error: String(localized: "This video's resolution needs more memory than this device can give, so it can't be played (´；ω；`)"))
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
    /// Shows or hides mpv's statistics overlay. mpv's script keeps the state to itself, so
    /// it is mirrored here; both start hidden with each player.
    func toggleStats() {
        showsStats.toggle()
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

    func text(_ text: PlayerText) -> String {
        texts[text] ?? text.defaultValue
    }

    func set(_ text: PlayerText, to value: String) {
        texts[text] = value
        player?.setProperty(text.rawValue, value)
    }

    func seek(to chapter: Chapter) {
        player?.setProperty("chapter", String(chapter.id))
    }

    func selectPlaylistEntry(_ entry: PlaylistEntry) {
        guard entry.id != playlistIndex else { return }
        onSelectPlaylistEntry?(entry.id)
    }

    func showAdjustments() {
        sidePanelContent = .adjustments
        showsAdjustments = true
    }

    func showContents() {
        sidePanelContent = .contents
        showsAdjustments = true
    }

    func showInfo() {
        sidePanelContent = .info
        showsAdjustments = true
    }

    /// The value of an observed diagnostic or info property as mpv prints it; nil while
    /// unknown or not applicable to the file.
    func property(_ name: String) -> String? {
        guard let value = diagnostics[name], !value.isEmpty, value != "-" else { return nil }
        return value
    }

    /// Jumps to an absolute position, exactly.
    func seek(toTime time: Double) {
        guard duration > 0 else { return }
        player?.command("seek", String(min(max(time, 0), duration)), "absolute+exact")
        keepControlsVisible()
    }

    /// Reads a typed time: seconds, `m:ss` or `h:mm:ss`. Nil if it is not one.
    nonisolated static func time(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
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
            tracks = withDiscLanguages((value.arrayValue ?? []).compactMap(MediaTrack.init))
            chooseDiscTracks()
            declineIfTooLarge(value.arrayValue ?? [])
            applyDolbyVisionPolicy(value.arrayValue ?? [])
            chooseInitialSubtitle()
        case "secondary-sid":
            secondarySubtitleID = value.stringValue.flatMap(Int.init)
        case "chapter-list":
            chapters = (value.arrayValue ?? []).enumerated().compactMap { index, chapter in
                guard let time = chapter["time"]?.doubleValue else { return nil }
                let title = chapter["title"]?.stringValue ?? ""
                return Chapter(
                    id: index,
                    title: title.isEmpty ? String(localized: "Chapter \(index + 1)") : title,
                    time: time
                )
            }
        case "chapter":
            currentChapter = value.intValue.flatMap { $0 >= 0 ? $0 : nil }
        default:
            if let number = PlayerNumber(rawValue: name) {
                let previous = numbers[number]
                numbers[number] = value.doubleValue
                // Fit and fill are switched by a pinch, which shows no control to confirm it.
                if number == .panscan, let panscan = value.doubleValue, panscan != previous {
                    announce(name) {
                        panscan > 0
                            ? OSDMessage(symbol: "arrow.up.left.and.arrow.down.right", text: String(localized: "Fill"))
                            : OSDMessage(symbol: "arrow.down.right.and.arrow.up.left", text: String(localized: "Fit"))
                    }
                }
            } else if let flag = PlayerFlag(rawValue: name) {
                flags[flag] = value.flagValue
            } else if let text = PlayerText(rawValue: name) {
                texts[text] = value.stringValue
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
