import SwiftUI

/// The controls when they have a half of the display to themselves (half-folded): laid out
/// like a remote rather than floating over the picture. Top to bottom: title, position,
/// transport, and the track and speed choices with their current values spelled out.
struct SplitControlPanel: View {
    let model: PlayerModel
    /// A vertical drag on the panel's empty space: which half it started in and the points
    /// moved since the last call (positive upwards), or nil travel when it begins.
    let onVerticalDrag: (_ isLeftHalf: Bool, _ travel: CGFloat?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 10)
            seek
            Spacer(minLength: 10)
            transport
            Spacer(minLength: 10)
            choices
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        // Behind the controls, so it only sees touches none of them took.
        .background { DragSurface(onVerticalDrag: onVerticalDrag) }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button("Close", systemImage: "xmark") { model.close() }
                .buttonStyle(GlassCircleButtonStyle())
            Text(model.title)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Playlist and Chapters", systemImage: "list.bullet") { model.showContents() }
                .buttonStyle(GlassCircleButtonStyle())
            Button("Adjustments", systemImage: "slider.horizontal.3") { model.showAdjustments() }
                .buttonStyle(GlassCircleButtonStyle())
            PlaybackMenu(model: model)
        }
    }

    private var seek: some View {
        VStack(spacing: 2) {
            SeekBar(
                position: model.position,
                duration: model.duration,
                bufferedEnd: model.bufferedEnd,
                marks: model.chapters.map(\.time),
                onScrub: model.scrub(to:),
                onScrubEnded: model.endScrub
            )
            HStack {
                Text(PlayerModel.format(time: model.position))
                Spacer()
                Text(PlayerModel.format(time: model.duration))
            }
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var transport: some View {
        HStack(spacing: model.hasPrevious || model.hasNext ? 36 : 52) {
            if model.hasPrevious || model.hasNext {
                Button("Previous", systemImage: "backward.end.fill") { model.step(-1) }
                    .font(.system(size: 24, weight: .medium))
                    .disabled(!model.hasPrevious)
                    .opacity(model.hasPrevious ? 1 : 0.35)
            }
            Button("Back 10 Seconds", systemImage: "gobackward.10") { model.skip(-10) }
                .font(.system(size: 32, weight: .medium))

            Button(model.isPaused ? "Play" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill") {
                model.togglePause()
            }
            .font(.system(size: 38, weight: .medium))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 88, height: 88)
            .glassEffect(.regular.interactive(), in: .circle)

            Button("Forward 10 Seconds", systemImage: "goforward.10") { model.skip(10) }
                .font(.system(size: 32, weight: .medium))
            if model.hasPrevious || model.hasNext {
                Button("Next", systemImage: "forward.end.fill") { model.step(1) }
                    .font(.system(size: 24, weight: .medium))
                    .disabled(!model.hasNext)
                    .opacity(model.hasNext ? 1 : 0.35)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
    }

    private var choices: some View {
        HStack(spacing: 12) {
            SubtitleMenu(model: model) {
                choice(
                    "Subtitles", symbol: "captions.bubble",
                    value: model.subtitleTracks.first(where: \.isSelected)?.displayName ?? String(localized: "Off")
                )
            }
            AudioMenu(model: model) {
                choice(
                    "Audio", symbol: "waveform",
                    value: model.audioTracks.first(where: \.isSelected)?.displayName ?? "-"
                )
            }
            .disabled(model.audioTracks.count < 2)
            SpeedMenu(model: model) {
                choice("Speed", symbol: "gauge.with.needle", value: PlayerModel.format(speed: model.speed))
            }
        }
    }

    /// A tile naming a setting and showing its current value; tapping it opens the menu.
    private func choice(_ title: LocalizedStringKey, symbol: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Text(value)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 58)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
        .contentShape(Rectangle())
    }
}

/// The panel's empty space: reports vertical drags, for brightness and volume.
private struct DragSurface: View {
    let onVerticalDrag: (_ isLeftHalf: Bool, _ travel: CGFloat?) -> Void

    // Whether the drag in progress turned out vertical, and how far it has been reported.
    @State private var isVertical: Bool?
    @State private var reported: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            let isLeftHalf = value.startLocation.x < geometry.size.width / 2
                            if isVertical == nil {
                                // The axis is locked by the initial direction, as on the picture.
                                isVertical = abs(value.translation.height) > abs(value.translation.width)
                                reported = value.translation.height
                                onVerticalDrag(isLeftHalf, nil)
                            }
                            guard isVertical == true else { return }
                            // Dragging up is negative height.
                            onVerticalDrag(isLeftHalf, reported - value.translation.height)
                            reported = value.translation.height
                        }
                        .onEnded { _ in isVertical = nil }
                )
        }
    }
}
