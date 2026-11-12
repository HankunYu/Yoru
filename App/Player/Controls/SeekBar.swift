import SwiftUI

/// A thin seek bar that thickens while dragged. Reports drag positions continuously and
/// the end of the drag separately, so the owner can seek coarsely first and exactly last.
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
                    Capsule()
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
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(width * fraction, 0))
            }
            .frame(height: isDragging ? 10 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        isDragging = true
                        onScrub(min(max(value.location.x / width, 0), 1) * duration)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onScrubEnded()
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
