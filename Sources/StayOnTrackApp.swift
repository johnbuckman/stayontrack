import SwiftUI
#if targetEnvironment(macCatalyst)
import UIKit
#endif

@main
struct StayOnTrackApp: App {
    @StateObject private var model = RouteModel()

    init() {
        #if targetEnvironment(macCatalyst)
        Self.observePhoneSizeLock()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // GPX open (share sheet / Files / open-in) is handled inside
                // ContentView so it can also reset an in-progress hike and start
                // following the new route.
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Open the Catalyst window at an iPhone 15 portrait size, but leave it
    /// freely resizable: momentarily pin min==max to force the initial size,
    /// then relax the restrictions so the user can resize.
    private static let phoneSize = CGSize(width: 393, height: 852)
    private static var didSetInitialSize = false

    private static func observePhoneSizeLock() {
        let apply: (Notification) -> Void = { note in
            guard let scene = note.object as? UIWindowScene,
                  let restrictions = scene.sizeRestrictions,
                  !didSetInitialSize else { return }
            didSetInitialSize = true
            restrictions.minimumSize = phoneSize
            restrictions.maximumSize = phoneSize
            // Relax on the next runloop so the window keeps the initial size
            // but becomes resizable.
            DispatchQueue.main.async {
                restrictions.minimumSize = CGSize(width: 320, height: 480)
                restrictions.maximumSize = CGSize(width: 4000, height: 4000)
            }
        }
        NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification,
                                               object: nil, queue: .main, using: apply)
        NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification,
                                               object: nil, queue: .main, using: apply)
    }
    #endif
}
