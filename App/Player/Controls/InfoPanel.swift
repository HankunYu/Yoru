import SwiftUI

/// What the playing file is, in a readable form: container, codecs and formats. mpv's own
/// statistics overlay has all of this and more, packed for diagnosing rather than reading.
struct InfoPanel: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 10) {
            Text("File Info")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Close", systemImage: "xmark") { model.hideAdjustments() }
                .buttonStyle(GlassCircleButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, model.adjustmentsRiseFromBottom ? 8 : 14)
        .padding(.bottom, 10)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("File", rows: fileRows)
                section("Video", rows: videoRows)
                section("Audio", rows: audioRows)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 20)
        }
        .sidePanelScrollFade()
    }

    private typealias InfoRow = (label: LocalizedStringKey, value: String)

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, rows: [InfoRow]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .textCase(.uppercase)
                ForEach(rows.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(rows[index].label)
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer(minLength: 8)
                        Text(verbatim: rows[index].value)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    /// A row for each value that is known; unknown ones are left out.
    private func rows(_ candidates: [(LocalizedStringKey, String?)]) -> [InfoRow] {
        candidates.compactMap { label, value in value.map { (label, $0) } }
    }

    private var fileRows: [InfoRow] {
        rows([
            ("Name", model.property("filename")),
            ("Container", model.property("file-format")),
            ("Size", model.property("file-size").flatMap(Int64.init)?.formatted(.byteCount(style: .file))),
            ("Duration", model.duration > 0 ? PlayerModel.format(time: model.duration) : nil),
            ("Chapters", model.chapters.isEmpty ? nil : String(model.chapters.count)),
        ])
    }

    private var videoRows: [InfoRow] {
        var resolution: String?
        if let width = model.property("video-params/w"), let height = model.property("video-params/h") {
            resolution = "\(width) × \(height)"
        }
        let frameRate = model.property("container-fps").flatMap(Double.init).map { String(format: "%.3f fps", $0) }
        let bitrate = model.property("video-bitrate").flatMap(Double.init).map(Self.format(bitrate:))
        return rows([
            ("Codec", model.property("video-codec")),
            ("Resolution", resolution),
            ("Frame Rate", frameRate),
            ("Pixel Format", model.property("video-params/pixelformat")),
            ("Primaries", model.property("video-params/primaries")),
            ("Transfer", model.property("video-params/gamma")),
            ("Matrix", model.property("video-params/colormatrix")),
            ("Range", model.property("video-params/colorlevels")),
            ("Bit Rate", bitrate),
            ("Decoder", model.property("hwdec-current").map { $0 == "no" ? String(localized: "Software") : $0 }),
        ])
    }

    private var audioRows: [InfoRow] {
        let sampleRate = model.property("audio-params/samplerate").flatMap(Double.init)
            .map { String(format: "%g kHz", $0 / 1000) }
        let bitrate = model.property("audio-bitrate").flatMap(Double.init).map(Self.format(bitrate:))
        return rows([
            ("Codec", model.property("audio-codec")),
            ("Channels", model.property("audio-params/hr-channels")),
            ("Sample Rate", sampleRate),
            ("Sample Format", model.property("audio-params/format")),
            ("Bit Rate", bitrate),
            ("Tracks", model.audioTracks.count > 1 ? String(model.audioTracks.count) : nil),
        ])
    }

    private static func format(bitrate: Double) -> String {
        bitrate >= 1_000_000 ? String(format: "%.1f Mbps", bitrate / 1_000_000) : String(format: "%.0f kbps", bitrate / 1000)
    }
}
