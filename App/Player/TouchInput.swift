import UIKit

/// Translates touches on the video into mpv `GESTURE_*` key presses.
///
/// What each gesture does is decided by mpv's input bindings (`TouchBindings`, overridable
/// in the user's input.conf), not here. Vertical drags and pinches are
/// quantized into repeated presses, the same way a mouse wheel produces ticks.
///
/// The horizontal drag is the exception: seeking has to follow the finger continuously,
/// which discrete key presses cannot express, so it is reported through `Scrub` instead.
@MainActor
final class TouchInput: NSObject, UIGestureRecognizerDelegate {
    enum Key: String {
        case tap = "GESTURE_TAP"
        case doubleTapLeft = "GESTURE_DOUBLE_TAP_LEFT"
        case doubleTapCenter = "GESTURE_DOUBLE_TAP_CENTER"
        case doubleTapRight = "GESTURE_DOUBLE_TAP_RIGHT"
        case leftUp = "GESTURE_LEFT_UP"
        case leftDown = "GESTURE_LEFT_DOWN"
        case rightUp = "GESTURE_RIGHT_UP"
        case rightDown = "GESTURE_RIGHT_DOWN"
        case pinchIn = "GESTURE_PINCH_IN"
        case pinchOut = "GESTURE_PINCH_OUT"
        case hold = "GESTURE_HOLD"
    }

    /// A horizontal drag, reported as the total travel in points since it began.
    enum Scrub {
        case began
        case moved(points: CGFloat)
        case ended
    }

    private enum PanAxis {
        case horizontal
        case vertical(isLeftHalf: Bool)
    }

    // Points of travel per emitted press.
    private static let slideStep: CGFloat = 9
    // Relative scale change per emitted press.
    private static let pinchStep: CGFloat = 0.04
    // Pans starting this close to the top or bottom edge belong to system gestures.
    private static let edgeInset: CGFloat = 28

    private let send: (Key) -> Void
    private let scrub: (Scrub) -> Void
    private let holdEnded: () -> Void
    private var scrubTravel: CGFloat = 0
    private weak var view: UIView?
    /// The part of the view showing the picture, in its coordinates; nil for all of it.
    /// Touches that start elsewhere (the controls' half of a half-folded display) are
    /// ignored; that area reports its own vertical drags through `verticalDrag`.
    var pictureRegion: CGRect?
    private var panAxis: PanAxis?
    private var panResidual: CGFloat = 0
    private var pinchReference: CGFloat = 1

    /// - Parameter holdEnded: Called when the finger lifts after a long press. mpv bindings
    ///   only fire on key down, so the end of a hold is reported separately.
    init(
        view: UIView,
        send: @escaping (Key) -> Void,
        scrub: @escaping (Scrub) -> Void,
        holdEnded: @escaping () -> Void
    ) {
        self.view = view
        self.send = send
        self.scrub = scrub
        self.holdEnded = holdEnded
        super.init()

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: doubleTap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold))
        hold.minimumPressDuration = 0.35

        for recognizer in [doubleTap, tap, pan, pinch, hold] {
            recognizer.delegate = self
            view.addGestureRecognizer(recognizer)
        }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        pictureRegion?.contains(touch.location(in: recognizer.view)) ?? true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let view, recognizer is UIPanGestureRecognizer else { return true }
        let y = recognizer.location(in: view).y
        return y > Self.edgeInset && y < view.bounds.height - Self.edgeInset
    }

    @objc private func handleTap() {
        send(.tap)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view, view.bounds.width > 0 else { return }
        doubleTap(atFraction: recognizer.location(in: view).x / view.bounds.width)
    }

    /// A double tap at `fraction` of the way across (0 leading, 1 trailing), sent as the
    /// key of the third it falls in. Also used for double taps recognized outside this
    /// object's own view.
    func doubleTap(atFraction fraction: CGFloat) {
        switch fraction {
        case ..<(1.0 / 3): send(.doubleTapLeft)
        case (2.0 / 3)...: send(.doubleTapRight)
        default: send(.doubleTapCenter)
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let view else { return }
        switch recognizer.state {
        case .began:
            // The axis is locked for the whole gesture by its initial direction.
            let velocity = recognizer.velocity(in: view)
            let start = recognizer.location(in: view)
            panAxis = abs(velocity.x) >= abs(velocity.y)
                ? .horizontal
                : .vertical(isLeftHalf: start.x < view.bounds.midX)
            panResidual = 0
            scrubTravel = 0
            recognizer.setTranslation(.zero, in: view)
            if case .horizontal = panAxis {
                scrub(.began)
            }
        case .changed:
            guard let panAxis else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            switch panAxis {
            case .horizontal:
                scrubTravel += translation.x
                scrub(.moved(points: scrubTravel))
            case .vertical(let isLeftHalf):
                // Dragging up is negative y.
                emitSteps(
                    -translation.y, step: Self.slideStep,
                    positive: isLeftHalf ? .leftUp : .rightUp,
                    negative: isLeftHalf ? .leftDown : .rightDown
                )
            }
        default:
            if case .horizontal = panAxis {
                scrub(.ended)
            }
            panAxis = nil
        }
    }

    @objc private func handleHold(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            send(.hold)
        case .ended, .cancelled, .failed:
            holdEnded()
        default:
            break
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            pinchReference = 1
        case .changed:
            while recognizer.scale >= pinchReference * (1 + Self.pinchStep) {
                pinchReference *= 1 + Self.pinchStep
                send(.pinchOut)
            }
            while recognizer.scale <= pinchReference * (1 - Self.pinchStep) {
                pinchReference *= 1 - Self.pinchStep
                send(.pinchIn)
            }
        default:
            break
        }
    }

    /// A vertical drag recognized outside this object's own view (the split control panel),
    /// fed through the same brightness / volume bindings as one on the picture.
    /// - Parameter travel: Points moved since the last call, positive upwards; nil when
    ///   the drag begins.
    func verticalDrag(isLeftHalf: Bool, travel: CGFloat?) {
        guard let travel else {
            panResidual = 0
            return
        }
        emitSteps(
            travel, step: Self.slideStep,
            positive: isLeftHalf ? .leftUp : .rightUp,
            negative: isLeftHalf ? .leftDown : .rightDown
        )
    }

    /// A long press recognized outside this object's own view began or was released; it
    /// goes through the same binding as one on the picture.
    func hold(_ isHolding: Bool) {
        if isHolding {
            send(.hold)
        } else {
            holdEnded()
        }
    }

    private func emitSteps(_ delta: CGFloat, step: CGFloat, positive: Key, negative: Key) {
        panResidual += delta
        while panResidual >= step {
            panResidual -= step
            send(positive)
        }
        while panResidual <= -step {
            panResidual += step
            send(negative)
        }
    }
}
