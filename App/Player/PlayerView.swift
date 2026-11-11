import UIKit

/// A view backed by `MetalLayer` that keeps the layer's drawable size in pixels in sync
/// with its bounds and reports it through `onLayout`. mpv does not watch the layer: the
/// owner must forward the size via the `moltenvk-surface-size` property.
final class PlayerView: UIView {
    override class var layerClass: AnyClass { MetalLayer.self }

    var metalLayer: MetalLayer { layer as! MetalLayer }

    /// Called after a layout pass has applied the new drawable size.
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        metalLayer.framebufferOnly = true
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: PlayerView, _) in
            view.setNeedsLayout()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
        onLayout?()
    }

    private func updateDrawableSize() {
        // Physical pixels per point. The UIKit scale (traitCollection.displayScale) can be
        // larger than the panel's (iPhone Duo inner display: 3.0 vs ~2.81); rendering at the
        // UIKit scale would make the system resample every frame down to the panel.
        let scale = window?.windowScene?.screen.nativeScale ?? traitCollection.displayScale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = size
    }
}
