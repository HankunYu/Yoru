import UIKit

/// Lets a screen restrict the interface orientation while it is shown.
///
/// SwiftUI presents its screens from hosting controllers the app does not subclass, so the
/// restriction is applied where UIKit asks last: the app delegate.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .all

    /// Restricts `scene` to `mask` and asks it to rotate there now. Pass `.all` to release.
    static func set(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene?) {
        guard mask != self.mask else { return }
        self.mask = mask
        guard let scene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            Log.app.error("Orientation request refused: \(error, privacy: .public)")
        }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
