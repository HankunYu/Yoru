import SwiftUI

/// Top bar: close, title and the playback menu.
struct PlayerTopBar: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            Button("Close", systemImage: "xmark") { model.close() }
                .buttonStyle(GlassCircleButtonStyle())

            Text(model.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .shadow(color: Theme.controlShadow, radius: 6, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)

            PlaybackMenu(model: model)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Audio / subtitle / speed selection and overlays.
private struct PlaybackMenu: View {
    let model: PlayerModel

    var body: some View {
        Menu {
            if !model.audioTracks.isEmpty {
                Menu("Audio", systemImage: "waveform") {
                    trackItems(model.audioTracks, kind: .audio, allowsNone: false)
                }
            }
            Menu("Subtitles", systemImage: "captions.bubble") {
                trackItems(model.subtitleTracks, kind: .sub, allowsNone: true)
            }
            Menu("Speed", systemImage: "gauge.with.dots.needle.50percent") {
                ForEach(PlayerModel.speeds, id: \.self) { speed in
                    Toggle(PlayerModel.format(speed: speed), isOn: Binding(
                        get: { abs(model.speed - speed) < 0.001 },
                        set: { _ in model.setSpeed(speed) }
                    ))
                }
            }
            Divider()
            Button("Statistics", systemImage: "chart.bar.xaxis") { model.toggleStats() }
            Toggle("Diagnostics", systemImage: "stethoscope", isOn: Binding(
                get: { model.showsDiagnostics },
                set: { model.showsDiagnostics = $0 }
            ))
        } label: {
            Label("Playback Options", systemImage: "ellipsis")
        }
        .buttonStyle(GlassCircleButtonStyle())
        .simultaneousGesture(TapGesture().onEnded { model.keepControlsVisible() })
    }

    @ViewBuilder
    private func trackItems(_ tracks: [MediaTrack], kind: MediaTrack.Kind, allowsNone: Bool) -> some View {
        if allowsNone {
            Toggle("Off", isOn: Binding(
                get: { !tracks.contains(where: \.isSelected) },
                set: { _ in model.select(nil, kind: kind) }
            ))
        }
        ForEach(tracks) { track in
            Toggle(track.displayName, isOn: Binding(
                get: { track.isSelected },
                set: { _ in model.select(track, kind: kind) }
            ))
        }
    }
}

/// Centered transport: skip back, play/pause, skip forward.
struct PlayerTransport: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 44) {
            Button("Back 10 Seconds", systemImage: "gobackward.10") { model.skip(-10) }
                .font(.system(size: 30, weight: .medium))

            Button(model.isPaused ? "Play" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                model.togglePause()
            }
            .font(.system(size: 52, weight: .medium))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 72, height: 72)

            Button("Forward 10 Seconds", systemImage: "goforward.10") { model.skip(10) }
                .font(.system(size: 30, weight: .medium))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .shadow(color: Theme.controlShadow, radius: 12, y: 2)
        .padding(20)
    }
}

/// Floating seek panel: elapsed time, seek bar, total time.
struct PlayerSeekPanel: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 14) {
            timeLabel(model.position)
            SeekBar(
                position: model.position,
                duration: model.duration,
                onScrub: model.scrub(to:),
                onScrubEnded: model.endScrub
            )
            timeLabel(model.duration)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 640)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(PlayerModel.format(time: seconds))
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize()
    }
}

/// A circular glass icon button.
struct GlassCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .glassEffect(.regular.interactive(), in: .circle)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
