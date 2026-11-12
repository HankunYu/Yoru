import Foundation

/// Converts PQ (HDR10) pixels to sRGB for thumbnails.
///
/// Core Graphics can do this conversion, but it places SDR white at 203 nits, which leaves
/// typical HDR video looking dim and gray next to SDR thumbnails. This puts it at 100 nits
/// and rolls the highlights off instead of clipping them.
enum HDRToneMap {
    /// Luminance, in nits, mapped to SDR white.
    private static let referenceWhite: Float = 100
    /// Output level above which highlights are compressed.
    private static let knee: Float = 0.8

    /// Linear light relative to `referenceWhite` for each 8-bit PQ code value.
    private static let linearFromPQ: [Float] = (0..<256).map { code in
        let m1: Float = 0.1593017578125, m2: Float = 78.84375
        let c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
        let power = pow(Float(code) / 255, 1 / m2)
        let nits = pow(max(power - c1, 0) / (c2 - c3 * power), 1 / m1) * 10_000
        return nits / referenceWhite
    }

    /// sRGB code value for linear light in 0...1, sampled at 1024 steps.
    private static let srgbFromLinear: [UInt8] = (0..<1024).map { step in
        let linear = Float(step) / 1023
        let encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return UInt8((encoded * 255).rounded())
    }

    /// Rewrites `pixelCount` BGRx pixels in place.
    static func convertPQToSRGB(_ buffer: UnsafeMutableRawPointer, pixelCount: Int, isBT2020: Bool) {
        let bytes = buffer.assumingMemoryBound(to: UInt8.self)
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            var blue = linearFromPQ[Int(bytes[offset])]
            var green = linearFromPQ[Int(bytes[offset + 1])]
            var red = linearFromPQ[Int(bytes[offset + 2])]

            if isBT2020 {
                // BT.2020 to BT.709 primaries; out-of-gamut colors clip at zero.
                let r = 1.6605 * red - 0.5876 * green - 0.0728 * blue
                let g = -0.1246 * red + 1.1329 * green - 0.0083 * blue
                let b = -0.0182 * red - 0.1006 * green + 1.1187 * blue
                red = max(r, 0)
                green = max(g, 0)
                blue = max(b, 0)
            }

            // Compress by the brightest channel, so highlights keep their hue.
            let peak = max(red, green, blue)
            if peak > knee {
                let compressed = knee + (1 - knee) * (1 - exp(-(peak - knee) / (1 - knee)))
                let scale = compressed / peak
                red *= scale
                green *= scale
                blue *= scale
            }

            bytes[offset] = srgbFromLinear[Int(min(blue, 1) * 1023)]
            bytes[offset + 1] = srgbFromLinear[Int(min(green, 1) * 1023)]
            bytes[offset + 2] = srgbFromLinear[Int(min(red, 1) * 1023)]
        }
    }
}
