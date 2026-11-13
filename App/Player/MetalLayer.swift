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

    /// How far above SDR white the screen can go; set before playback starts.
    var potentialHeadroom: CGFloat = 1

    /// The peak, in nits, HDR output is rendered to and described with. One value for
    /// every video: what a file's mastering metadata claims is often a placeholder (10 000
    /// nits is common), and fitting to that leaves the picture dim. mpv brings brighter
    /// material down to this from what the frames actually contain; it is also HLG's
    /// nominal peak.
    static let outputPeakNits: CGFloat = 1000

    /// What white is, in nits, in the description given to the system: the level of the
    /// interface around the video. Subtitles are drawn at it.
    static let whiteNits: CGFloat = 100

    /// The peak, in nits, that the output is described with while it is HDR; nil while it
    /// is not. Called on the main thread whenever it changes.
    var onOutputPeakChange: ((CGFloat?) -> Void)?
    private var outputPeak: CGFloat?

    // MoltenVK gives the layer the color space of the surface mpv chose, and on iOS that
    // is all it does: nothing asks the display for its extended range. Without the ask an
    // HDR picture is clipped at SDR white, unless another app happens to have the display
    // in HDR already. So the layer asks, whenever its color space is an HDR one.
    override var colorspace: CGColorSpace? {
        get { super.colorspace }
        set {
            super.colorspace = newValue
            let isHDR = newValue.map { CGColorSpaceUsesITUR_2100TF($0) || CGColorSpaceUsesExtendedRange($0) } ?? false
            // Set from mpv's render thread; the display only follows on the main thread.
            nonisolated(unsafe) let layer = self
            let apply = { layer.setExtendedRange(isHDR) }
            if Thread.isMainThread {
                apply()
            } else {
                DispatchQueue.main.async(execute: apply)
            }
        }
    }

    private func setExtendedRange(_ isOn: Bool) {
        // The flag is the request up to iOS 25. From iOS 26 a layer states the dynamic
        // range it prefers and how much headroom its drawables use.
        wantsExtendedDynamicRangeContent = isOn
        preferredDynamicRange = isOn ? .high : .standard
        contentsHeadroom = isOn && potentialHeadroom > 1 ? potentialHeadroom : 0
        updateMetadata()
    }

    /// Describes the picture to the system, which then fits its highlights into whatever
    /// the display can show right now: that changes with the brightness setting and the
    /// light in the room. Without a description the system shows the values as they are
    /// and cuts off what the display cannot reach, which reads as overexposure.
    ///
    /// mpv has to render to the same peak. Left to guess, it takes a PQ output to reach
    /// 10 000 nits and scales HLG, whose brightness follows the display's, up to that.
    private func updateMetadata() {
        var peak: CGFloat?
        if let colorspace, CGColorSpaceUsesITUR_2100TF(colorspace) {
            if colorspace.name == CGColorSpace.itur_2100_HLG {
                edrMetadata = .hlg
            } else {
                edrMetadata = .hdr10(
                    minLuminance: 0.005, maxLuminance: Float(Self.outputPeakNits), opticalOutputScale: Float(Self.whiteNits)
                )
            }
            peak = Self.outputPeakNits
        } else {
            edrMetadata = nil
        }
        if peak != outputPeak {
            outputPeak = peak
            onOutputPeakChange?(peak)
        }
    }
}
