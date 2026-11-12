import SwiftUI

/// The second-level panel for everything adjusted while watching, beyond picking a track:
/// timing, subtitle appearance, picture and playback. Changes apply at once and playback
/// continues, so their effect can be judged against the picture.
struct AdjustmentPanel: View {
    let model: PlayerModel
    @State private var tab = Tab.subtitles

    private enum Tab: CaseIterable {
        case subtitles
        case audio
        case picture
        case playback

        var title: LocalizedStringKey {
            switch self {
            case .subtitles: "Subtitles"
            case .audio: "Audio"
            case .picture: "Picture"
            case .playback: "Playback"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.adjustmentsRiseFromBottom {
                Capsule()
                    .fill(.white.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                Picker("Adjustments", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                Button("Close", systemImage: "xmark") { model.hideAdjustments() }
                    .buttonStyle(GlassCircleButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.top, model.adjustmentsRiseFromBottom ? 8 : 14)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 22) {
                    switch tab {
                    case .subtitles: SubtitleAdjustments(model: model)
                    case .audio: AudioAdjustments(model: model)
                    case .picture: PictureAdjustments(model: model)
                    case .playback: PlaybackAdjustments(model: model)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)
            // Fades the content out toward the bottom edge instead of slicing through a row.
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9),
                            .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        // The scrolling content is cut off along the panel's outline, not its bounding box.
        .clipShape(Self.outline)
        .glassEffect(.regular, in: Self.outline)
    }

    /// Concentric with the display's own corners, whatever the panel's distance from them.
    private static var outline: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: 22), isUniform: true)
    }
}

// MARK: - Tabs

private struct SubtitleAdjustments: View {
    let model: PlayerModel

    var body: some View {
        DelayRow(model: model, number: .subtitleDelay)
        SliderRow(
            title: "Size",
            valueText: model.number(.subtitleScale).formatted(.percent.precision(.fractionLength(0))),
            value: model.binding(.subtitleScale),
            range: 0.5...2,
            step: 0.05
        )
        SliderRow(
            title: "Vertical Position",
            valueText: "\(Int(model.number(.subtitlePosition).rounded()))",
            value: model.binding(.subtitlePosition),
            range: 60...100,
            step: 1
        )
        Button("Use Size and Position as Default") { saveAsDefault() }
            .buttonStyle(PanelButtonStyle())
        Toggle("Show Subtitles", isOn: model.binding(.subtitlesVisible))
            .tint(Theme.accent)
        Row(title: "Second Subtitle") {
            Menu {
                Toggle("Off", isOn: Binding(
                    get: { model.secondarySubtitleID == nil },
                    set: { _ in model.selectSecondarySubtitle(nil) }
                ))
                ForEach(model.subtitleTracks) { track in
                    Toggle(track.displayName, isOn: Binding(
                        get: { model.secondarySubtitleID == track.id },
                        set: { _ in model.selectSecondarySubtitle(track) }
                    ))
                }
            } label: {
                Text(secondaryName)
                    .lineLimit(1)
                    .modifier(PanelChip())
            }
            .menuOrder(.fixed)
        }
    }

    private var secondaryName: String {
        model.subtitleTracks.first { $0.id == model.secondarySubtitleID }?.displayName ?? String(localized: "Off")
    }

    /// Writes the two values into mpv.conf, where Settings reads them too.
    private func saveAsDefault() {
        let previous = PlayerOptions.load()
        var options = previous
        options.subtitleScale = model.number(.subtitleScale)
        options.subtitlePosition = Int(model.number(.subtitlePosition).rounded())
        options.save(changedFrom: previous)
    }
}

private struct AudioAdjustments: View {
    let model: PlayerModel

    var body: some View {
        DelayRow(model: model, number: .audioDelay)
        SliderRow(
            title: "Volume Boost",
            valueText: "\(Int(model.number(.volume).rounded()))%",
            value: model.binding(.volume),
            range: 100...200,
            step: 5
        )
        Text("Raises quiet audio above its normal level, on top of the system volume. May distort when set high.")
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PictureAdjustments: View {
    let model: PlayerModel

    private static let equalizer: [(PlayerNumber, LocalizedStringKey)] = [
        (.brightness, "Brightness"), (.contrast, "Contrast"), (.saturation, "Saturation"), (.gamma, "Gamma"),
    ]

    var body: some View {
        Row(title: "Aspect") {
            Picker("Aspect", selection: Binding(get: { model.aspectMode }, set: model.setAspectMode)) {
                Text("Fit").tag(AspectMode.fit)
                Text("Fill").tag(AspectMode.fill)
                Text("Stretch").tag(AspectMode.stretch)
                Text(verbatim: "16:9").tag(AspectMode.wide)
                Text(verbatim: "4:3").tag(AspectMode.standard)
            }
            .pickerStyle(.menu)
            .tint(.white)
        }
        Row(title: "Rotation") {
            Picker("Rotation", selection: model.binding(.rotation)) {
                ForEach([0.0, 90, 180, 270], id: \.self) { degrees in
                    Text(verbatim: "\(Int(degrees))°").tag(degrees)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
        ForEach(Self.equalizer, id: \.0) { number, title in
            SliderRow(
                title: title,
                valueText: "\(Int(model.number(number).rounded()))",
                value: model.binding(number),
                range: -100...100,
                step: 1
            )
        }
        Button("Reset Picture") {
            for (number, _) in Self.equalizer {
                model.set(number, to: 0)
            }
        }
        .buttonStyle(PanelButtonStyle())
        Toggle("Debanding", isOn: model.binding(.deband))
            .tint(Theme.accent)
    }
}

private struct PlaybackAdjustments: View {
    let model: PlayerModel

    var body: some View {
        SliderRow(
            title: "Speed",
            valueText: PlayerModel.format(speed: model.speed),
            value: Binding(get: { model.speed }, set: model.setSpeed),
            range: 0.25...4,
            step: 0.05
        )
        Button("Normal Speed") { model.setSpeed(1) }
            .buttonStyle(PanelButtonStyle())
        VStack(alignment: .leading, spacing: 10) {
            Text("A-B Loop")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 10) {
                loopPoint("A", number: .loopStart)
                loopPoint("B", number: .loopEnd)
                Button("Clear") {
                    model.clear(.loopStart)
                    model.clear(.loopEnd)
                }
                .buttonStyle(PanelButtonStyle())
                .disabled(!model.isSet(.loopStart) && !model.isSet(.loopEnd))
            }
            Text("Repeats the part between A and B.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// A button placing one end of the loop at the current position; shows where it is once placed.
    private func loopPoint(_ name: String, number: PlayerNumber) -> some View {
        Button {
            model.set(number, to: model.position)
        } label: {
            VStack(spacing: 2) {
                Text(verbatim: name)
                    .font(.subheadline.weight(.semibold))
                Text(verbatim: model.isSet(number) ? PlayerModel.format(time: model.number(number)) : "–")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PanelButtonStyle())
    }
}

// MARK: - Rows

/// A delay stepped in tenths of a second.
private struct DelayRow: View {
    let model: PlayerModel
    let number: PlayerNumber

    private static let step = 0.1

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Delay")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: String(format: "%+.1f s", value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 10) {
                Button { step(by: -Self.step) } label: {
                    Text(verbatim: "−0.1").frame(maxWidth: .infinity)
                }
                .buttonRepeatBehavior(.enabled)
                Button("Reset") { model.set(number, to: 0) }
                    .disabled(abs(value) < 0.001)
                Button { step(by: Self.step) } label: {
                    Text(verbatim: "+0.1").frame(maxWidth: .infinity)
                }
                .buttonRepeatBehavior(.enabled)
            }
            .buttonStyle(PanelButtonStyle())
        }
    }

    private var value: Double { model.number(number) }

    private func step(by amount: Double) {
        // Rounded so repeated steps do not drift off the tenths.
        model.set(number, to: ((value + amount) * 10).rounded() / 10)
    }
}

private struct SliderRow: View {
    let title: LocalizedStringKey
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(verbatim: valueText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            Slider(value: $value, in: range, step: step)
                .tint(Theme.accent)
        }
    }
}

/// A titled row with a control at its trailing edge.
private struct Row<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 12)
            content
        }
    }
}

private struct PanelChip: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(.white.opacity(0.12), in: .rect(cornerRadius: 12))
    }
}

private struct PanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PanelChip())
            .opacity(!isEnabled ? 0.35 : configuration.isPressed ? 0.6 : 1)
    }
}

private extension PlayerModel {
    func binding(_ number: PlayerNumber) -> Binding<Double> {
        Binding(get: { self.number(number) }, set: { self.set(number, to: $0) })
    }

    func binding(_ flag: PlayerFlag) -> Binding<Bool> {
        Binding(get: { self.flag(flag) }, set: { self.set(flag, to: $0) })
    }
}
