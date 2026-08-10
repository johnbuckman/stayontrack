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
                // GPX shared to the app / opened from Files.
                .onOpenURL { url in
                    model.load(from: url)
                }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Lock the Catalyst window to an iPhone 15 portrait size for realistic
    /// testing. Applied on scene connect AND activate — onAppear runs too early
    /// (before the scene's size restrictions exist), so the restore wins.
    private static let phoneSize = CGSize(width: 393, height: 852)

    private static func observePhoneSizeLock() {
        let apply: (Notification) -> Void = { note in
            guard let scene = note.object as? UIWindowScene,
                  let restrictions = scene.sizeRestrictions else { return }
            restrictions.minimumSize = phoneSize
            restrictions.maximumSize = phoneSize
        }
        NotificationCenter.default.addObserver(forName: UIScene.willConnectNotification,
                                               object: nil, queue: .main, using: apply)
        NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification,
                                               object: nil, queue: .main, using: apply)
    }
    #endif
}
