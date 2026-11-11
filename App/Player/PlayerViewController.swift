import UIKit

/// Full-screen player: owns one `MPVPlayer`, the render view, the minimal control overlay
/// and the iOS lifecycle glue (background audio, foldable posture).
///
/// M0 spike: the overlay also shows a diagnostics panel used to verify rendering,
/// hardware decoding, HDR and the iPhone Duo fold on device.
final class PlayerViewController: UIViewController {
    var onClose: (() -> Void)?

    private let location: String
    private let playerView = PlayerView()
    // Taps outside the controls fall through to the player view's tap recognizer.
    private let overlay = PassthroughView()
    private let diagnosticsLabel = UILabel()
    private let timeLabel = UILabel()
    private let seekSlider = UISlider()
    private lazy var playPauseButton = makeButton(systemImage: "pause.fill") { [weak self] in
        self?.player?.command("cycle", "pause")
    }

    private var player: MPVPlayer?
    private var eventTask: Task<Void, Never>?
    private var postureMonitor: PostureMonitor?
    private var savedVideoTrack = "auto"

    private var isPaused = false
    private var timePosition: Double = 0
    private var duration: Double = 0
    private var properties: [String: String] = [:]

    init(location: String) {
        self.location = location
        super.init(nibName: nil, bundle: nil)
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
        buildViewHierarchy()

        let monitor = PostureMonitor(view: playerView)
        monitor.onChange = { [weak self] posture in self?.apply(posture) }
        monitor.onUpdate = { [weak self] in self?.updateDiagnostics() }
        postureMonitor = monitor
        // Driven by the player view's own layout pass, which runs after the controller's.
        playerView.onLayout = { [weak self] in
            self?.syncSurfaceSize()
            self?.postureMonitor?.invalidate()
            self?.updateDiagnostics()
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleOverlay))
        playerView.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification, object: nil
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
        let edrHeadroom = view.window?.windowScene?.screen.potentialEDRHeadroom ?? 1
        var options: [(name: String, value: String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("keep-open", "yes"),
            ("save-position-on-quit", "yes"),
            ("input-default-bindings", "yes"),
            ("watch-later-dir", ConfigDirectory.url.appending(path: "watch_later").path),
            // Default and fallback subtitle font; see ConfigDirectory for why it is bundled.
            ("sub-font", "Noto Sans CJK SC"),
        ]
        // target-colorspace-hint cannot change at runtime and moltenvk does not report the
        // display, so the app decides up front from the screen's EDR capability.
        if edrHeadroom > 1 {
            options.append(("target-colorspace-hint", "yes"))
        }
        #if DEBUG
        options.append(("log-file", ConfigDirectory.url.appending(path: "mpv.log").path))
        #endif
        properties["edr-headroom"] = String(format: "%.2f", edrHeadroom)

        do {
            let player = try MPVPlayer(
                layer: playerView.metalLayer,
                configDirectory: ConfigDirectory.url,
                options: options
            )
            self.player = player
            syncSurfaceSize()
            observeProperties(of: player)
            eventTask = Task { [weak self] in
                for await event in player.events {
                    self?.handle(event)
                }
            }
            player.command("loadfile", location)
        } catch {
            Log.player.error("Starting mpv failed: \(error.description, privacy: .public)")
            properties["error"] = error.description
            updateDiagnostics()
        }
    }

    /// Tells mpv the layer's pixel size; this is what makes it resize its swapchain and
    /// repaint, including while paused.
    private func syncSurfaceSize() {
        let size = playerView.metalLayer.drawableSize
        guard size.width > 1, size.height > 1 else { return }
        player?.setProperty("moltenvk-surface-size", "\(Int(size.width))x\(Int(size.height))")
    }

    private func stopPlayer() {
        eventTask?.cancel()
        eventTask = nil
        player?.destroy()
        player = nil
    }

    private func observeProperties(of player: MPVPlayer) {
        player.observe("pause", format: .flag)
        player.observe("time-pos", format: .double)
        player.observe("duration", format: .double)
        // Cached so the background handler can restore it without a synchronous read.
        player.observe("vid", format: .string)
        for name in Self.diagnosticProperties {
            player.observe(name, format: .string)
        }
    }

    private static let diagnosticProperties = [
        "hwdec-current",
        "video-params/pixelformat",
        "video-params/gamma",
        "video-params/sig-peak",
        "video-out-params/w",
        "video-out-params/h",
        "current-tracks/sub/codec",
        "estimated-vf-fps",
        "frame-drop-count",
        "decoder-frame-drop-count",
        "video-bitrate",
    ]

    private func handle(_ event: MPVEvent) {
        switch event {
        case .propertyChanged(let name, let value):
            handleProperty(name, value)
        case .log(let prefix, let level, let text):
            Log.mpv.info("[\(prefix, privacy: .public)] \(level, privacy: .public): \(text, privacy: .public)")
            #if DEBUG
            // os.Logger doesn't reach `devicectl --console`; mirror mpv logs to stdout while debugging.
            print("[mpv/\(prefix)] \(level): \(text)", terminator: "")
            #endif
        case .fileLoaded, .videoReconfig:
            updateDiagnostics()
        case .endFile, .playbackRestart, .shutdown:
            break
        }
    }

    private func handleProperty(_ name: String, _ value: MPVValue) {
        switch name {
        case "pause":
            isPaused = value.flagValue ?? false
            playPauseButton.configuration?.image = UIImage(systemName: isPaused ? "play.fill" : "pause.fill")
        case "time-pos":
            let newPosition = value.doubleValue ?? 0
            if !seekSlider.isTracking {
                seekSlider.value = Float(newPosition)
            }
            guard Int(newPosition) != Int(timePosition) else {
                timePosition = newPosition
                return
            }
            timePosition = newPosition
            updateTimeLabel()
        case "duration":
            duration = value.doubleValue ?? 0
            seekSlider.maximumValue = Float(duration)
            updateTimeLabel()
        default:
            properties[name] = value.stringValue ?? "-"
            updateDiagnostics()
        }
    }

    // MARK: - Seeking

    @objc private func seekSliderChanged() {
        // Keyframe seeks while dragging stay responsive on long files.
        player?.command("seek", String(seekSlider.value), "absolute+keyframes")
        timePosition = Double(seekSlider.value)
        updateTimeLabel()
    }

    @objc private func seekSliderReleased() {
        #if DEBUG
        print("[yoru] seek released at \(seekSlider.value)")
        #endif
        player?.command("seek", String(seekSlider.value), "absolute+exact")
    }

    // MARK: - Posture

    private func apply(_ posture: Posture) {
        let bottomRatio: Double
        switch posture {
        case .tabletop(let fold):
            // Push the picture above the fold; the controls stay in the lower half.
            let height = playerView.bounds.height
            bottomRatio = height > 0 ? max(0, min(1, (height - fold.minY) / height)) : 0
        case .flat, .closed:
            bottomRatio = 0
        }
        player?.setProperty("video-margin-ratio-bottom", String(bottomRatio))
    }

    // MARK: - App lifecycle

    @objc private func appDidEnterBackground() {
        guard let player else { return }
        // Keep audio playing in the background but stop rendering; rendering into a
        // backgrounded layer leaves it black when returning.
        savedVideoTrack = properties["vid"].flatMap { $0 == "-" ? nil : $0 } ?? "auto"
        player.setProperty("vid", "no")
        // iOS may kill a backgrounded app without a quit, so persist the position now.
        player.command("write-watch-later-config")
    }

    @objc private func appWillEnterForeground() {
        player?.setProperty("vid", savedVideoTrack)
    }

    // MARK: - Overlay

    @objc private func toggleOverlay() {
        let hidden = overlay.alpha > 0
        UIView.animate(withDuration: 0.2) {
            self.overlay.alpha = hidden ? 0 : 1
        }
    }

    private func buildViewHierarchy() {
        playerView.translatesAutoresizingMaskIntoConstraints = false
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(playerView)
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let closeButton = makeButton(systemImage: "xmark") { [weak self] in self?.onClose?() }
        let statsButton = makeButton(systemImage: "chart.bar.xaxis") { [weak self] in
            // Built-in Lua script: verifies LuaJIT is live.
            self?.player?.command("script-binding", "stats/display-stats-toggle")
        }
        let topBar = UIStackView(arrangedSubviews: [closeButton, UIView(), statsButton])
        topBar.axis = .horizontal

        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnosticsLabel.textColor = .white
        diagnosticsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.5)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        timeLabel.textColor = .white
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        seekSlider.addTarget(self, action: #selector(seekSliderChanged), for: .valueChanged)
        seekSlider.addTarget(self, action: #selector(seekSliderReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let bottomBar = UIStackView(arrangedSubviews: [playPauseButton, seekSlider, timeLabel])
        bottomBar.axis = .horizontal
        bottomBar.alignment = .center
        bottomBar.spacing = 12

        for subview in [topBar, diagnosticsLabel, bottomBar] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(subview)
        }
        let guide = overlay.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            diagnosticsLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
            diagnosticsLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            diagnosticsLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            bottomBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
        ])
    }

    private func makeButton(systemImage: String, action: @escaping @MainActor () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: systemImage)
        configuration.cornerStyle = .capsule
        return UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    }

    private func updateTimeLabel() {
        timeLabel.text = "\(Self.format(timePosition)) / \(Self.format(duration))"
    }

    private func updateDiagnostics() {
        var lines = Self.diagnosticProperties.map { "\($0): \(properties[$0] ?? "-")" }
        lines.append("edr-headroom: \(properties["edr-headroom"] ?? "-")")
        let scale = playerView.metalLayer.contentsScale
        lines.append(String(
            format: "view: %.0fx%.0f pt @%.2fx  drawable: %.0fx%.0f",
            playerView.bounds.width, playerView.bounds.height, scale,
            playerView.metalLayer.drawableSize.width, playerView.metalLayer.drawableSize.height
        ))
        // HDR ground truth: what the layer was configured for and what the display is doing now.
        let layer = playerView.metalLayer
        let colorSpace = layer.colorspace?.name.map { ($0 as String).replacingOccurrences(of: "kCGColorSpace", with: "") } ?? "nil"
        lines.append("layer: \(colorSpace) fmt=\(layer.pixelFormat.rawValue) wantsEDR=\(layer.wantsExtendedDynamicRangeContent)")
        if let screen = view.window?.windowScene?.screen {
            lines.append(String(format: "screen EDR: current=%.2f potential=%.2f", screen.currentEDRHeadroom, screen.potentialEDRHeadroom))
        }
        lines.append("size class: w=\(Self.name(traitCollection.horizontalSizeClass)) h=\(Self.name(traitCollection.verticalSizeClass))")
        if let monitor = postureMonitor {
            lines.append("posture: \(monitor.posture)")
            if let hinge = monitor.hinge {
                lines.append(String(format: "hinge: %@ %.1f°", String(describing: hinge.status), hinge.angle * 180 / .pi))
            } else {
                lines.append("hinge: none")
            }
            for region in monitor.divisionRegions {
                lines.append("division: \(region.frame.integral) active=\(region.isActive) margins=\(region.margins)")
            }
        }
        if let error = properties["error"] {
            lines.append("ERROR: \(error)")
        }
        diagnosticsLabel.text = lines.joined(separator: "\n")
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? seconds : 0)
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func name(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: "compact"
        case .regular: "regular"
        default: "unspecified"
        }
    }
}

/// A view that ignores touches on itself so they reach the views beneath.
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
