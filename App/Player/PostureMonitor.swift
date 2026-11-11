import UIKit

/// How the device is being held, as far as video layout is concerned.
enum Posture: Equatable {
    /// Flat (or a device without a hinge).
    case flat
    /// Half-folded with a horizontal fold; `fold` is the division region in the observed view's coordinates.
    case tabletop(fold: CGRect)
    /// Folded shut; the app is on the outer display.
    case closed
}

/// Derives `Posture` from the hinge state and the view's fold (division) reserved region.
///
/// The fold position comes from `UIView.reservedRegions(kind: .division)`; it is never
/// assumed to be the middle of the screen. Call `invalidate()` from the observed view's
/// layout pass so region changes are picked up.
@MainActor
final class PostureMonitor {
    private(set) var posture: Posture = .flat
    private(set) var hinge: UIHinge?
    private(set) var divisionRegions: [UIView.ReservedRegion] = []

    var onChange: ((Posture) -> Void)?
    /// Called on every re-evaluation, for diagnostics.
    var onUpdate: (() -> Void)?

    private weak var view: UIView?

    init(view: UIView) {
        self.view = view
        let interaction = UIHingeInteraction { [weak self] _, update in
            self?.hinge = update.hinge
            self?.invalidate()
        }
        view.addInteraction(interaction)
    }

    func invalidate() {
        guard let view else { return }
        divisionRegions = view.reservedRegions(kind: .division, options: .includeInactive)
        let newPosture = Self.posture(hinge: hinge, regions: divisionRegions)
        onUpdate?()
        guard newPosture != posture else { return }
        posture = newPosture
        Log.player.info("Posture changed: \(String(describing: newPosture), privacy: .public)")
        onChange?(newPosture)
    }

    private static func posture(hinge: UIHinge?, regions: [UIView.ReservedRegion]) -> Posture {
        if hinge?.status == .closed {
            return .closed
        }
        if let fold = regions.first(where: { $0.isActive })?.frame, fold.width > fold.height {
            return .tabletop(fold: fold)
        }
        return .flat
    }
}
