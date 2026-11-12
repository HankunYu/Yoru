import SwiftUI

/// A thin seek bar that thickens while dragged. Reports drag positions continuously and
/// the end of the drag separately, so the owner can seek coarsely first and exactly last.
///
/// A drag moves the position from where it is by the distance the finger travels, a full
/// bar's width being the whole duration. It does not jump to the finger: the finger
/// covers the spot it presses, so the jump could not be aimed.
struct SeekBar: View {
    let position: Double
    let duration: Double
    /// The time up to which the file is buffered; shown as a lighter stretch of the track.
    var bufferedEnd: Double = 0
    /// Times marked on the track: where chapters begin.
    var marks: [Double] = []
    let onScrub: (Double) -> Void
    let onScrubEnded: () -> Void

    @State private var isDragging = false
    /// Where the drag in progress began: the position then and the bar's width then, so
    /// neither the scrubbing itself nor a layout change moves the reference.
    @State private var origin: (position: Double, width: CGFloat)?

    private var fraction: Double {
        duration > 0 ? min(max(position / duration, 0), 1) : 0
    }

    private var bufferedFraction: Double {
        duration > 0 ? min(max(bufferedEnd / duration, 0), 1) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                // Drawn from the start; the played part covers all but what lies ahead.
                if bufferedFraction > fraction {
                    Rectangle()
                        .fill(.white.opacity(0.35))
                        .frame(width: width * bufferedFraction)
                }
                // Chapter starts as gaps in the track; the very beginning needs none.
                ForEach(marks.filter { $0 > 0 && $0 < duration }, id: \.self) { mark in
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: 2)
                        .offset(x: width * mark / duration - 1)
                }
                .zIndex(1)
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: max(width * fraction, 0))
            }
            .frame(height: isDragging ? 10 : 4)
            // Everything is cut to the track's shape: a fill narrower than the track is
            // tall, or a mark near an end, would otherwise poke out of the rounded caps.
            .clipShape(.capsule)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                // Global coordinates: the bar may shift under the finger while it is dragged.
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        isDragging = true
                        // A touch that has not moved is not a scrub yet.
                        guard origin != nil || abs(value.translation.width) >= 1 else { return }
                        let origin = origin ?? (position, width)
                        self.origin = origin
                        let offset = value.translation.width / origin.width * duration
                        onScrub(min(max(origin.position + offset, 0), duration))
                    }
                    .onEnded { _ in
                        isDragging = false
                        if origin != nil {
                            origin = nil
                            onScrubEnded()
                        }
                    }
            )
            .animation(.snappy(duration: 0.18), value: isDragging)
        }
        .frame(height: 32)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue(PlayerModel.format(time: position))
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 10.0 : -10.0
            onScrub(min(max(position + step, 0), duration))
            onScrubEnded()
        }
    }
}
