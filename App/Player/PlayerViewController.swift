import SwiftUI
import UIKit

/// Full-screen player. Owns one `MPVPlayer` and its render view, and composes the pieces
/// around it: touch input, the SwiftUI controls, lock screen integration, and the iOS
/// lifecycle glue (background audio, foldable posture).
final class PlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    // The file being played; replaced when moving through the folder.
    private var target: PlaybackTarget
    private let endAction = YoruOptions.load().endAction
    // The app saves positions on its own schedule too, and must not when resuming is off.
    private let resumesPlayback = PlayerOptions.load().resumesPlayback
    private let model = PlayerModel()
    private let playerView = PlayerView()

    private var player: MPVPlayer?
    private var eventTask: Task<Void, Never>?
    private var resumeSaveTask: Task<Void, Never>?
    private var touchInput: TouchInput?
    private var postureMonitor: PostureMonitor?
    private var nowPlaying: NowPlayingSession?
    private var systemVolume: SystemVolume?
    private var controlHosts: [UIView] = []
    // Shown instead of `controlHosts` while the controls have their own half of the display.
    private var splitPanel: UIView?
    // The adjustments panel; laid out by frame, since where it goes depends on the posture.
    private var adjustmentPanel: UIView?
    // Whether the panel is on screen, as far as its slide animation is concerned.
    private var isAdjustmentPanelPresented = false
    // The full-width control rows and their trailing/leading edge constraints, adjusted by
    // `updateControlInsets()` to step around occlusions.
    private var controlRows: [(host: UIView, leading: NSLayoutConstraint, trailing: NSLayoutConstraint)] = []
    // The area the controls are laid out in: the safe area, or one half when half-folded.
    private let controlsGuide = UILayoutGuide()
    private var controlsGuideTop: NSLayoutConstraint?
    private var controlsGuideBottom: NSLayoutConstraint?
    // The backdrop (messages, buffering) follows the picture.
    private var backdropTop: NSLayoutConstraint?
    private var backdropBottom: NSLayoutConstraint?
    private var appliedMargins = VideoMargins()
    private var savedVideoTrack = "auto"
    private var currentVideoTrack: String?
    private var edrHeadroom: CGFloat = 1

    init(target: PlaybackTarget, onClose: @escaping () -> Void) {
        self.target = target
        super.init(nibName: nil, bundle: nil)
        model.onClose = onClose
        MediaPreviewStore.shared.suspend()
    }

    deinit {
        MediaPreviewStore.shared.resume()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark
        buildViewHierarchy()

        touchInput = TouchInput(
            view: playerView,
            send: { [weak self] key in self?.player?.command("keypress", key.rawValue) },
            scrub: { [weak self] scrub in self?.model.handle(scrub) },
            holdEnded: { [weak self] in self?.model.endHoldSpeed() }
        )

        let monitor = PostureMonitor(view: playerView)
        monitor.onChange = { [weak self] posture in self?.apply(posture) }
        postureMonitor = monitor
        // Driven by the player view's own layout pass, which runs after the controller's.
        playerView.onLayout = { [weak self] in
            self?.syncSurfaceSize()
            self?.postureMonitor?.invalidate()
        }

        model.adjustBrightness = { [weak self] delta in
            guard let screen = self?.view.window?.windowScene?.screen else { return 0 }
            screen.brightness = min(max(screen.brightness + delta, 0), 1)
            return screen.brightness
        }
        let volume = SystemVolume(hostView: view)
        volume.onChange = { [weak self] level in self?.model.systemVolumeDidChange(level) }
        model.adjustSystemVolume = { [weak volume] delta in volume?.adjust(by: delta) }
        systemVolume = volume
        trackControlsVisibility()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveResumePosition),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(saveResumePosition),
            name: UIApplication.willTerminateNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification, object: nil
        )
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Started here rather than in viewDidLoad: the EDR capability depends on the screen
        // the view is actually on.
        if player == nil {
            startPlayer()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || parent?.isBeingDismissed == true {
            stopPlayer()
        }
    }

    // MARK: - Player lifecycle

    private func startPlayer() {
        edrHeadroom = view.window?.windowScene?.screen.potentialEDRHeadroom ?? 1
        var options: [(name: String, value: String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("keep-open", "yes"),
            // Headroom for the adjustments panel's volume boost.
            ("volume-max", "200"),
            ("save-position-on-quit", "yes"),
            ("input-default-bindings", "yes"),
            ("watch-later-dir", ConfigDirectory.url.appending(path: "watch_later").path),
            // Lets WatchHistory map saved positions back to files.
            ("write-filename-in-watch-later-config", "yes"),
            // What is remembered per file: the position (`start` has to be listed, it is
            // not implied), the chosen tracks and their timing. Narrower than mpv's default
            // list, which would also bring back the speed and the zoom, and `vid`, which
            // the app turns off in the background.
            ("watch-later-options", "start,aid,sid,sub-visibility,sub-delay,audio-delay"),
            // A track picked by number means nothing in the next file, and its timing and
            // loop points belong to this one. Speed and picture adjustments carry over.
            ("reset-on-next-file", "aid,sid,secondary-sid,sub-visibility,sub-delay,audio-delay,ab-loop-a,ab-loop-b"),
            // Default and fallback subtitle font; see ConfigDirectory for why it is bundled.
            ("sub-font", "Noto Sans CJK SC"),
            ("osd-font", "Noto Sans CJK SC"),
        ]
        // target-colorspace-hint cannot change at runtime and moltenvk does not report the
        // display, so the app decides up front from the screen's EDR capability.
        if edrHeadroom > 1 {
            options.append(("target-colorspace-hint", "yes"))
        }
        #if DEBUG
        options.append(("log-file", ConfigDirectory.url.appending(path: "mpv.log").path))
        #endif

        do {
            let player = try MPVPlayer(
                layer: playerView.metalLayer,
                configDirectory: ConfigDirectory.url,
                options: options,
                streamProtocols: MediaSources.streamProtocols
            )
            self.player = player
            syncSurfaceSize()
            loadTouchBindings(into: player)
            model.attach(player)
            model.onStep = { [weak self] offset in self?.step(offset) }
            model.onReachedEnd = { [weak self] in self?.playbackReachedEnd() }
            // Cached so the background handler can restore it without a synchronous read.
            player.observe("vid", format: .string)
            nowPlaying = NowPlayingSession(model: model)
            startSavingResumePosition()
            eventTask = Task { [weak self] in
                for await event in player.events {
                    self?.handle(event)
                }
            }
            load(target)
        } catch {
            Log.player.error("Starting mpv failed: \(error.description, privacy: .public)")
            model.report(error: error.description)
        }
    }

    /// Opens `target` in the running player, replacing whatever is playing.
    private func load(_ target: PlaybackTarget) {
        guard let player else { return }
        self.target = target
        let index = target.queue?.index(of: target)
        model.hasPrevious = index.map { $0 > 0 } ?? false
        model.hasNext = index.map { $0 + 1 < (target.queue?.items.count ?? 0) } ?? false
        model.initialSubtitleChoice = target.initialSubtitleChoice
        model.beginLoading()

        // Given up front rather than added once the file is loaded, so they take part in
        // mpv's track selection, and a remembered `sid` can point at one of them.
        // Replaces what the previous file set, so a login never travels to another server.
        player.setProperty("http-header-fields", target.httpHeaders.joined(separator: ","))
        player.command("change-list", "sub-files", "clr", "")
        for subtitle in target.externalSubtitles {
            player.command("change-list", "sub-files", "append", subtitle)
        }
        if target.forcesCache {
            player.command("loadfile", target.location, "replace", "-1", "cache=yes")
        } else {
            player.command("loadfile", target.location)
        }
    }

    /// Moves to the previous (-1) or next (1) file of the folder.
    private func step(_ offset: Int) {
        guard let queue = target.queue, let index = queue.index(of: target),
              queue.items.indices.contains(index + offset) else { return }
        forgetOrSaveResumePosition()
        load(queue.target(at: index + offset))
        // The file being left may have been paused, by the user or at its end.
        player?.setProperty("pause", "no")
    }

    private func playbackReachedEnd() {
        switch endAction {
        case .next where model.hasNext:
            step(1)
        case .close:
            model.onClose?()
        case .next, .stay:
            break
        }
    }

    /// Saves where the current file was left; a file left at its end or in its credits
    /// is forgotten instead, so it starts over next time.
    /// - Parameter isQuitting: mpv is about to quit, which would write the position again.
    private func forgetOrSaveResumePosition(isQuitting: Bool = false) {
        saveResumePosition()
        if isQuitting, model.isNearEnd {
            player?.setProperty("save-position-on-quit", "no")
        }
    }

    private func stopPlayer() {
        eventTask?.cancel()
        eventTask = nil
        nowPlaying?.invalidate()
        nowPlaying = nil
        systemVolume?.invalidate()
        systemVolume = nil
        model.detach()
        OrientationLock.set(.all, in: view.window?.windowScene)
        resumeSaveTask?.cancel()
        resumeSaveTask = nil
        forgetOrSaveResumePosition(isQuitting: true)
        player?.destroy {
            Task { @MainActor in WatchHistory.shared.reload() }
        }
        player = nil
    }

    /// Installs the built-in touch bindings as a default input section, so bindings for
    /// the same keys in the user's input.conf win.
    private func loadTouchBindings(into player: MPVPlayer) {
        player.command("define-section", "yoru-touch", TouchBindings.section(for: YoruOptions.load()), "default")
        player.command("enable-section", "yoru-touch")
    }

    /// Tells mpv the layer's pixel size; this is what makes it resize its swapchain and
    /// repaint, including while paused.
    private func syncSurfaceSize() {
        let size = playerView.metalLayer.drawableSize
        guard size.width > 1, size.height > 1 else { return }
        player?.setProperty("moltenvk-surface-size", "\(Int(size.width))x\(Int(size.height))")
    }

    private func handle(_ event: MPVEvent) {
        switch event {
        case .propertyChanged(name: "vid", let value):
            currentVideoTrack = value.stringValue
        case .log(let prefix, let level, let text):
            Log.mpv.info("[\(prefix, privacy: .public)] \(level, privacy: .public): \(text, privacy: .public)")
            #if DEBUG
            // os.Logger doesn't reach `devicectl --console`; mirror mpv logs to stdout while debugging.
            print("[mpv/\(prefix)] \(level): \(text)", terminator: "")
            #endif
        case .endFile(.endOfFile):
            // Only reached when mpv.conf sets `keep-open=no`; otherwise mpv pauses on the
            // last frame and the model reports the end. There is no frame to stay on here.
            if endAction == .next, model.hasNext {
                step(1)
            } else {
                model.onClose?()
            }
        default:
            model.handle(event)
        }
    }

    // MARK: - Posture

    private struct VideoMargins: Equatable {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
    }

    private static func update(_ constraint: NSLayoutConstraint?, to constant: CGFloat) {
        if let constraint, constraint.constant != constant {
            constraint.constant = constant
        }
    }

    private func apply(_ posture: Posture) {
        let scene = view.window?.windowScene
        // Half-folded, the fold should lie across: the player turns to portrait, either way up.
        if case .halfFolded = posture {
            OrientationLock.set([.portrait, .portraitUpsideDown], in: scene)
        } else {
            OrientationLock.set(.all, in: scene)
        }
        updateSplit()
    }

    /// Lays the player out for the current posture: half-folded with a horizontal fold, the
    /// picture takes the upper half and the controls the lower; otherwise the picture
    /// fills the view and the controls float over it.
    private func updateSplit() {
        let bounds = view.bounds
        var videoRegion: CGRect?
        var controlRegion: CGRect?
        if case .halfFolded(let fold) = postureMonitor?.posture, fold.width > fold.height, bounds.height > 0 {
            videoRegion = CGRect(x: 0, y: 0, width: bounds.width, height: fold.minY)
            controlRegion = CGRect(x: 0, y: fold.maxY, width: bounds.width, height: bounds.height - fold.maxY)
        }

        let insets = view.safeAreaInsets
        let video = videoRegion ?? bounds
        let controls = controlRegion ?? bounds
        // Each region keeps the safe-area inset of the screen edge it touches.
        // This runs on every layout pass, so nothing is touched unless it changed.
        Self.update(controlsGuideTop, to: max(controls.minY, insets.top))
        Self.update(controlsGuideBottom, to: -max(bounds.maxY - controls.maxY, insets.bottom))
        Self.update(backdropTop, to: video.minY)
        Self.update(backdropBottom, to: -(bounds.maxY - video.maxY))

        let height = max(bounds.height, 1)
        let margins = VideoMargins(top: video.minY / height, bottom: (bounds.maxY - video.maxY) / height)
        if margins != appliedMargins, let player {
            appliedMargins = margins
            player.setProperty("video-margin-ratio-top", String(Double(margins.top)))
            player.setProperty("video-margin-ratio-bottom", String(Double(margins.bottom)))
        }
        touchInput?.pictureRegion = videoRegion
        model.setDedicatedControlArea(controlRegion != nil)
    }

    // MARK: - App lifecycle

    /// Writes the resume file now, or removes it when the file is as good as finished.
    ///
    /// mpv writes it when it quits, but deletes the previous one as soon as a file is
    /// opened, and iOS can end the app with no chance to quit mpv: swiped away in the app
    /// switcher, or killed in the background. So the position is also saved whenever the
    /// app stops being active, and every so often while playing.
    @objc private func saveResumePosition() {
        guard resumesPlayback else { return }
        // Near the end there is nothing worth resuming, and what an earlier save left
        // behind has to go too.
        player?.command(model.isNearEnd ? "delete-watch-later-config" : "write-watch-later-config")
    }

    private func startSavingResumePosition() {
        resumeSaveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.saveResumePosition()
            }
        }
    }

    @objc private func appDidEnterBackground() {
        guard let player else { return }
        // Keep audio playing in the background but stop rendering; rendering into a
        // backgrounded layer leaves it black when returning.
        savedVideoTrack = currentVideoTrack ?? "auto"
        player.setProperty("vid", "no")
        saveResumePosition()
    }

    @objc private func appWillEnterForeground() {
        player?.setProperty("vid", savedVideoTrack)
    }

    // MARK: - Controls

    /// Each interactive control group is its own hosting view sized to its content, so
    /// touches anywhere else reach the player view's gesture recognizers.
    private func buildViewHierarchy() {
        playerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)

        let backdrop = host(PlayerBackdrop(model: model) { [weak self] in self?.environmentDiagnostics() ?? [] })
        backdrop.isUserInteractionEnabled = false
        let topBar = host(PlayerTopBar(model: model))
        let transport = host(PlayerTransport(model: model))
        let seekPanel = host(PlayerBottomBar(model: model))
        controlHosts = [topBar, transport, seekPanel]
        let splitPanel = host(
            SplitControlPanel(model: model) { [weak self] isLeftHalf, travel in
                self?.touchInput?.verticalDrag(isLeftHalf: isLeftHalf, travel: travel)
            },
            fillsItsFrame: true
        )
        self.splitPanel = splitPanel
        let adjustmentPanel = host(AdjustmentPanel(model: model), fillsItsFrame: true)
        adjustmentPanel.translatesAutoresizingMaskIntoConstraints = true
        adjustmentPanel.alpha = 0
        let dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleAdjustmentPanelPan))
        dismissPan.delegate = self
        adjustmentPanel.addGestureRecognizer(dismissPan)
        self.adjustmentPanel = adjustmentPanel

        view.addLayoutGuide(controlsGuide)
        let guide = controlsGuide
        let guideTop = guide.topAnchor.constraint(equalTo: view.topAnchor)
        let guideBottom = guide.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        controlsGuideTop = guideTop
        controlsGuideBottom = guideBottom
        let backdropTop = backdrop.topAnchor.constraint(equalTo: view.topAnchor)
        let backdropBottom = backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        self.backdropTop = backdropTop
        self.backdropBottom = backdropBottom
        // Horizontally both rows span the whole view, not the safe area. On the iPhone Duo's
        // outer display the safe area reserves a full-height 84pt strip for a camera that
        // only occupies one corner; honoring it would leave every row visibly off-center.
        // Each row instead avoids just the occlusions that overlap it.
        controlRows = [topBar, seekPanel].map { row in
            (row, row.leadingAnchor.constraint(equalTo: view.leadingAnchor),
             view.trailingAnchor.constraint(equalTo: row.trailingAnchor))
        }
        NSLayoutConstraint.activate(controlRows.flatMap { [$0.leading, $0.trailing] })
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            backdropTop,
            backdropBottom,
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            topBar.topAnchor.constraint(equalTo: guide.topAnchor),

            transport.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            transport.centerYAnchor.constraint(equalTo: guide.centerYAnchor),

            splitPanel.topAnchor.constraint(equalTo: guide.topAnchor),
            splitPanel.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            splitPanel.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            splitPanel.trailingAnchor.constraint(equalTo: guide.trailingAnchor),

            guideTop,
            guideBottom,
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            seekPanel.bottomAnchor.constraint(equalTo: guide.bottomAnchor),

        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSplit()
        updateControlInsets()
        layoutAdjustmentPanel()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    /// Insets each control row past the active occlusion regions (camera housing and the
    /// system area around it) that overlap that row vertically.
    private func updateControlInsets() {
        let occlusions = view.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
        for row in controlRows {
            var leading: CGFloat = 0
            var trailing: CGFloat = 0
            for frame in occlusions where frame.maxY > row.host.frame.minY && frame.minY < row.host.frame.maxY {
                if frame.midX < view.bounds.midX {
                    leading = max(leading, frame.maxX)
                } else {
                    trailing = max(trailing, view.bounds.width - frame.minX)
                }
            }
            if row.leading.constant != leading { row.leading.constant = leading }
            if row.trailing.constant != trailing { row.trailing.constant = trailing }
        }
    }

    /// Half-folded, the panel takes the controls' half. Otherwise it is a drawer along the
    /// trailing edge on a wide view and a sheet along the bottom on a tall one, leaving as
    /// much of the picture visible as it can.
    ///
    /// It keeps the same distance from every display edge it sits against, so its corners
    /// can follow the display's. The safe area is not used: its bottom inset is for a home
    /// indicator that is hidden while playing, and its side inset on the outer display
    /// reserves a full-height strip for a camera in one corner. The panel instead steps
    /// aside only for an occlusion that would actually overlap it.
    private func layoutAdjustmentPanel() {
        guard let adjustmentPanel else { return }
        let margin: CGFloat = 10
        let bounds = view.bounds
        var frame: CGRect
        if model.hasDedicatedControlArea {
            let top = controlsGuide.layoutFrame.minY
            frame = CGRect(
                x: margin, y: top + margin,
                width: bounds.width - margin * 2, height: bounds.maxY - top - margin * 2
            )
        } else if bounds.width > bounds.height {
            let width = min(360, bounds.width * 0.5)
            frame = CGRect(
                x: bounds.maxX - margin - width, y: margin,
                width: width, height: bounds.height - margin * 2
            )
        } else {
            let height = min(440, bounds.height * 0.5)
            frame = CGRect(
                x: margin, y: bounds.maxY - margin - height,
                width: bounds.width - margin * 2, height: height
            )
        }
        for occlusion in view.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
        where occlusion.intersects(frame) {
            // Give up the strip beside the occlusion, on whichever side it is.
            if occlusion.midX > bounds.midX {
                frame.size.width = max(occlusion.minX - margin - frame.minX, 0)
            } else {
                let shift = occlusion.maxX + margin - frame.minX
                frame.origin.x += shift
                frame.size.width = max(frame.width - shift, 0)
            }
        }
        // Position through bounds and center: the frame is undefined while the panel is
        // transformed, which it is whenever it slides.
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if adjustmentPanel.bounds.size != frame.size || adjustmentPanel.center != center {
            adjustmentPanel.bounds.size = frame.size
            adjustmentPanel.center = center
        }
        let risesFromBottom = model.hasDedicatedControlArea || bounds.width <= bounds.height
        if model.adjustmentsRiseFromBottom != risesFromBottom {
            model.adjustmentsRiseFromBottom = risesFromBottom
        }
        // Parked off screen while fully hidden, ready to slide in. Not while it is still
        // sliding out: a layout pass then would cut the animation short.
        if !isAdjustmentPanelPresented, adjustmentPanel.alpha == 0 {
            adjustmentPanel.transform = adjustmentPanelOffscreenTransform
        }
    }

    /// Moves the panel past the display edge it comes from: the bottom, or the trailing side.
    private var adjustmentPanelOffscreenTransform: CGAffineTransform {
        guard let adjustmentPanel else { return .identity }
        let size = adjustmentPanel.bounds.size
        let center = adjustmentPanel.center
        if model.adjustmentsRiseFromBottom {
            return CGAffineTransform(translationX: 0, y: view.bounds.maxY - (center.y - size.height / 2))
        }
        return CGAffineTransform(translationX: view.bounds.maxX - (center.x - size.width / 2), y: 0)
    }

    private func setAdjustmentPanelPresented(_ presented: Bool) {
        guard let adjustmentPanel, presented != isAdjustmentPanelPresented else { return }
        isAdjustmentPanelPresented = presented
        if presented {
            view.layoutIfNeeded()
            adjustmentPanel.alpha = 1
        }
        adjustmentPanel.isUserInteractionEnabled = presented
        UIView.animate(
            withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            adjustmentPanel.transform = presented ? .identity : self.adjustmentPanelOffscreenTransform
        } completion: { _ in
            if !self.isAdjustmentPanelPresented {
                adjustmentPanel.alpha = 0
            }
        }
    }

    /// Dragging the panel toward the edge it came from moves it along; letting go far
    /// enough, or fast enough, sends it away.
    @objc private func handleAdjustmentPanelPan(_ recognizer: UIPanGestureRecognizer) {
        guard let adjustmentPanel, isAdjustmentPanelPresented else { return }
        let vertical = model.adjustmentsRiseFromBottom
        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        let travel = max(vertical ? translation.y : translation.x, 0)
        let speed = vertical ? velocity.y : velocity.x
        let extent = vertical ? adjustmentPanel.bounds.height : adjustmentPanel.bounds.width
        switch recognizer.state {
        case .changed:
            adjustmentPanel.transform = vertical
                ? CGAffineTransform(translationX: 0, y: travel)
                : CGAffineTransform(translationX: travel, y: 0)
        case .ended, .cancelled:
            if recognizer.state == .ended, travel > extent / 3 || speed > 600 {
                model.hideAdjustments()
            } else {
                UIView.animate(
                    withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction]
                ) {
                    adjustmentPanel.transform = .identity
                }
            }
        default:
            break
        }
    }

    // The dismiss drag must not steal touches from the panel's own controls.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view, current !== adjustmentPanel {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let adjustmentPanel else { return true }
        let velocity = pan.velocity(in: view)
        if model.adjustmentsRiseFromBottom {
            // The content scrolls vertically, so only the strip with the grabber drags the panel.
            return pan.location(in: adjustmentPanel).y < 30 && velocity.y > abs(velocity.x)
        }
        return velocity.x > abs(velocity.y)
    }

    // Lets this drag be decided before the content's scroll view claims the touch.
    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        other.view is UIScrollView
    }

    /// - Parameter fillsItsFrame: The view is sized by its constraints rather than by its content.
    private func host(_ content: some View, fillsItsFrame: Bool = false) -> UIView {
        let controller = UIHostingController(rootView: content)
        controller.sizingOptions = fillsItsFrame ? [] : .intrinsicContentSize
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        return controller.view
    }

    /// Fades the interactive controls with the model's state: the floating ones with
    /// `controlsVisible`, replaced by the split panel while the controls have their own
    /// area. Hidden controls must not swallow touches, hence UIKit-level alpha and
    /// interaction rather than SwiftUI opacity.
    private func trackControlsVisibility() {
        let (visible, dedicated, adjusting) = withObservationTracking {
            (model.controlsVisible, model.hasDedicatedControlArea, model.showsAdjustments)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackControlsVisibility() }
        }
        // The adjustments panel stands in for whichever controls would otherwise show.
        let showsFloating = visible && !dedicated && !adjusting
        let showsSplit = dedicated && !adjusting
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            for host in self.controlHosts {
                host.alpha = showsFloating ? 1 : 0
            }
            self.splitPanel?.alpha = showsSplit ? 1 : 0
        }
        setAdjustmentPanelPresented(adjusting)
        for host in controlHosts {
            host.isUserInteractionEnabled = showsFloating
        }
        splitPanel?.isUserInteractionEnabled = showsSplit
    }

    // MARK: - Diagnostics

    private func environmentDiagnostics() -> [String] {
        let layer = playerView.metalLayer
        var lines = [String(format: "edr-headroom (at start): %.2f", edrHeadroom)]
        lines.append(String(
            format: "view: %.0fx%.0f pt @%.2fx  drawable: %.0fx%.0f",
            playerView.bounds.width, playerView.bounds.height, layer.contentsScale,
            layer.drawableSize.width, layer.drawableSize.height
        ))
        let colorSpace = layer.colorspace?.name.map { ($0 as String).replacingOccurrences(of: "kCGColorSpace", with: "") } ?? "nil"
        lines.append("layer: \(colorSpace) wantsEDR=\(layer.wantsExtendedDynamicRangeContent)")
        if let screen = view.window?.windowScene?.screen {
            lines.append(String(format: "screen EDR: current=%.2f potential=%.2f", screen.currentEDRHeadroom, screen.potentialEDRHeadroom))
        }
        if let monitor = postureMonitor {
            lines.append("posture: \(monitor.posture)")
            if let hinge = monitor.hinge {
                lines.append(String(format: "hinge: status=%d %.1f°", hinge.status.rawValue, hinge.angle * 180 / .pi))
            }
            for region in monitor.divisionRegions {
                lines.append("division: \(region.frame.integral) active=\(region.isActive)")
            }
        }
        let insets = view.safeAreaInsets
        lines.append(String(format: "safe area: t=%.0f l=%.0f b=%.0f r=%.0f", insets.top, insets.left, insets.bottom, insets.right))
        for region in view.reservedRegions(kind: .occlusion, options: .includeInactive) {
            lines.append("occlusion: \(region.frame.integral) active=\(region.isActive)")
        }
        return lines
    }
}
