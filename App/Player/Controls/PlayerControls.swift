import SwiftUI

/// Top bar: close, title and the playback menu.
struct PlayerTopBar: View {
    let model: PlayerModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

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
        .padding(.horizontal, ControlMetrics.edgeInset(horizontalSizeClass))
        .padding(.top, ControlMetrics.topInset(horizontalSizeClass))
        .padding(.bottom, 8)
    }
}

/// Distance of the control rows from the screen edges.
///
/// Large displays (the iPhone Duo's inner screen) report no safe-area inset at the top or
/// sides, yet have generously rounded corners, so the rows need more room there than the
/// safe area asks for.
enum ControlMetrics {
    static func edgeInset(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 30 : 16
    }

    static func topInset(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 22 : 8
    }

    static func bottomInset(_ sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .regular ? 14 : 8
    }
}

/// Overlays that are rarely needed: mpv's statistics and Yoru's diagnostics.
struct PlaybackMenu: View {
    let model: PlayerModel

    var body: some View {
        Menu {
            Button("Statistics", systemImage: "chart.bar.xaxis") { model.toggleStats() }
            Toggle("Diagnostics", systemImage: "stethoscope", isOn: Binding(
                get: { model.showsDiagnostics },
                set: { model.showsDiagnostics = $0 }
            ))
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .buttonStyle(GlassCircleButtonStyle())
        .simultaneousGesture(TapGesture().onEnded { model.keepControlsVisible() })
    }
}

/// Centered transport: skip back, play/pause, skip forward.
struct PlayerTransport: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: model.hasPrevious || model.hasNext ? 30 : 44) {
            if model.hasPrevious || model.hasNext {
                Button("Previous", systemImage: "backward.end.fill") { model.step(-1) }
                    .font(.system(size: 22, weight: .medium))
                    .disabled(!model.hasPrevious)
                    .opacity(model.hasPrevious ? 1 : 0.35)
            }
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
            if model.hasPrevious || model.hasNext {
                Button("Next", systemImage: "forward.end.fill") { model.step(1) }
                    .font(.system(size: 22, weight: .medium))
                    .disabled(!model.hasNext)
                    .opacity(model.hasNext ? 1 : 0.35)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .shadow(color: Theme.controlShadow, radius: 12, y: 2)
        .padding(20)
    }
}

/// Bottom row: the seek capsule and, to its right, the quick panel.
struct PlayerBottomBar: View {
    let model: PlayerModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        HStack(spacing: 10) {
            seekCapsule
            QuickPanel(model: model)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, ControlMetrics.edgeInset(horizontalSizeClass))
        .padding(.bottom, ControlMetrics.bottomInset(horizontalSizeClass))
    }

    private var seekCapsule: some View {
        HStack(spacing: 14) {
            timeLabel(model.position)
            SeekBar(
                position: model.position,
                duration: model.duration,
                bufferedEnd: model.bufferedEnd,
                marks: model.chapters.map(\.time),
                onScrub: model.scrub(to:),
                onScrubEnded: model.endScrub
            )
            timeLabel(model.duration)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
    }

    private func timeLabel(_ seconds: Double) -> some View {
        Text(PlayerModel.format(time: seconds))
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize()
    }
}

/// The things changed most while watching, one tap away: subtitles, audio, speed.
private struct QuickPanel: View {
    let model: PlayerModel

    var body: some View {
        HStack(spacing: 2) {
            SubtitleMenu(model: model) {
                item(Image(systemName: "captions.bubble"), label: "Subtitles")
            }
            if model.audioTracks.count > 1 {
                AudioMenu(model: model) {
                    item(Image(systemName: "waveform"), label: "Audio")
                }
            }
            SpeedMenu(model: model) {
                item(
                    Text(PlayerModel.format(speed: model.speed))
                        .font(.footnote.weight(.semibold).monospacedDigit()),
                    label: "Speed"
                )
            }
            Button { model.showContents() } label: {
                item(Image(systemName: "list.bullet"), label: "Playlist and Chapters")
            }
            Button { model.showAdjustments() } label: {
                item(Image(systemName: "slider.horizontal.3"), label: "Adjustments")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .simultaneousGesture(TapGesture().onEnded { model.keepControlsVisible() })
    }

    private func item(_ content: some View, label: LocalizedStringKey) -> some View {
        content
            .font(.system(size: 16, weight: .medium))
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }
}

/// Picks the subtitle track, or none.
struct SubtitleMenu<Label: View>: View {
    let model: PlayerModel
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            Toggle("Off", isOn: Binding(
                get: { !model.subtitleTracks.contains(where: \.isSelected) },
                set: { _ in model.select(nil, kind: .sub) }
            ))
            TrackItems(model: model, tracks: model.subtitleTracks, kind: .sub)
        } label: {
            label
        }
        .menuOrder(.fixed)
    }
}

/// Picks the audio track.
struct AudioMenu<Label: View>: View {
    let model: PlayerModel
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            TrackItems(model: model, tracks: model.audioTracks, kind: .audio)
        } label: {
            label
        }
        .menuOrder(.fixed)
    }
}

/// Picks the playback speed.
struct SpeedMenu<Label: View>: View {
    let model: PlayerModel
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            ForEach(PlayerModel.speeds, id: \.self) { speed in
                Toggle(PlayerModel.format(speed: speed), isOn: Binding(
                    get: { abs(model.speed - speed) < 0.001 },
                    set: { _ in model.setSpeed(speed) }
                ))
            }
        } label: {
            label
        }
        .menuOrder(.fixed)
    }
}

private struct TrackItems: View {
    let model: PlayerModel
    let tracks: [MediaTrack]
    let kind: MediaTrack.Kind

    var body: some View {
        ForEach(tracks) { track in
            Toggle(track.displayName, isOn: Binding(
                get: { track.isSelected },
                set: { _ in model.select(track, kind: kind) }
            ))
        }
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
