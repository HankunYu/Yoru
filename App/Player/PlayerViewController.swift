import SwiftUI
import UIKit

/// Full-screen player. Owns one `MPVPlayer` and its render view, and composes the pieces
/// around it: touch input, the SwiftUI controls, lock screen integration, and the iOS
/// lifecycle glue (background audio, foldable posture).
final class PlayerViewController: UIViewController {
    private let location: String
    private let model = PlayerModel()
    private let playerView = PlayerView()

    private var player: MPVPlayer?
    private var eventTask: Task<Void, Never>?
    private var touchInput: TouchInput?
    private var postureMonitor: PostureMonitor?
    private var nowPlaying: NowPlayingSession?
    private var controlHosts: [UIView] = []
    private var savedVideoTrack = "auto"
    private var currentVideoTrack: String?
    private var edrHeadroom: CGFloat = 1

    init(location: String, onClose: @escaping () -> Void) {
        self.location = location
        super.init(nibName: nil, bundle: nil)
        model.onClose = onClose
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
            scrub: { [weak self] scrub in self?.model.handle(scrub) }
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
        trackControlsVisibility()

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
        edrHeadroom = view.window?.windowScene?.screen.potentialEDRHeadroom ?? 1
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
                options: options
            )
            self.player = player
            syncSurfaceSize()
            loadTouchBindings(into: player)
            model.attach(player)
            // Cached so the background handler can restore it without a synchronous read.
            player.observe("vid", format: .string)
            nowPlaying = NowPlayingSession(model: model)
            eventTask = Task { [weak self] in
                for await event in player.events {
                    self?.handle(event)
                }
            }
            player.command("loadfile", location)
        } catch {
            Log.player.error("Starting mpv failed: \(error.description, privacy: .public)")
            model.report(error: error.description)
        }
    }

    private func stopPlayer() {
        eventTask?.cancel()
        eventTask = nil
        nowPlaying?.invalidate()
        nowPlaying = nil
        model.detach()
        player?.destroy()
        player = nil
    }

    /// Installs the bundled touch bindings as a default input section, so bindings for
    /// the same keys in the user's input.conf win.
    private func loadTouchBindings(into player: MPVPlayer) {
        guard let url = Bundle.main.url(forResource: "touch", withExtension: "conf"),
              let bindings = try? String(contentsOf: url, encoding: .utf8) else {
            Log.player.error("touch.conf missing from bundle")
            return
        }
        player.command("define-section", "yoru-touch", bindings, "default")
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
        default:
            model.handle(event)
        }
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
        savedVideoTrack = currentVideoTrack ?? "auto"
        player.setProperty("vid", "no")
        // iOS may kill a backgrounded app without a quit, so persist the position now.
        player.command("write-watch-later-config")
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
        let seekPanel = host(PlayerSeekPanel(model: model))
        controlHosts = [topBar, transport, seekPanel]

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: view.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            topBar.topAnchor.constraint(equalTo: guide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor),

            transport.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            transport.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            seekPanel.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            seekPanel.centerXAnchor.constraint(equalTo: guide.centerXAnchor),
            seekPanel.widthAnchor.constraint(lessThanOrEqualTo: guide.widthAnchor),
            seekPanel.widthAnchor.constraint(equalTo: guide.widthAnchor).withPriority(.defaultHigh),
        ])
    }

    private func host(_ content: some View) -> UIView {
        let controller = UIHostingController(rootView: content)
        controller.sizingOptions = .intrinsicContentSize
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        return controller.view
    }

    /// Fades the interactive controls with `model.controlsVisible`. Hidden controls must
    /// not swallow touches, hence UIKit-level alpha and interaction rather than SwiftUI opacity.
    private func trackControlsVisibility() {
        let visible = withObservationTracking {
            model.controlsVisible
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackControlsVisibility() }
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            for host in self.controlHosts {
                host.alpha = visible ? 1 : 0
            }
        }
        for host in controlHosts {
            host.isUserInteractionEnabled = visible
        }
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
        return lines
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
