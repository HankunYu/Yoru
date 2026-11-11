import QuartzCore

/// The layer mpv renders into through MoltenVK.
final class MetalLayer: CAMetalLayer {
    // MoltenVK sets drawableSize to 1x1 to force-complete a presentation, which causes
    // flicker and can leave the size stuck. https://github.com/mpv-player/mpv/pull/13651
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            guard newValue.width > 1, newValue.height > 1 else { return }
            super.drawableSize = newValue
        }
    }

    // mpv toggles EDR from its render thread, but the display only switches into EDR mode
    // when this is set on the main thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                // The render thread blocks until the main thread has applied the value,
                // so handing the layer over is race-free.
                nonisolated(unsafe) let layer = self
                DispatchQueue.main.sync {
                    layer.setSuperWantsExtendedDynamicRangeContent(newValue)
                }
            }
        }
    }

    private func setSuperWantsExtendedDynamicRangeContent(_ value: Bool) {
        super.wantsExtendedDynamicRangeContent = value
    }
}
