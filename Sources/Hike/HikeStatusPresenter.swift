import Foundation
import UserNotifications
#if !targetEnvironment(macCatalyst)
import ActivityKit
#endif

#if !targetEnvironment(macCatalyst)
/// Shared Live Activity data (iPhone). The widget extension renders this.
struct HikeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var instruction: String     // e.g. "Keep left"
        var meters: Int             // distance to the junction
    }
    var routeName: String
}
#endif

/// Presents the "next junction" status where the OS supports it:
///   • iPhone  → a Live Activity (Lock Screen + Dynamic Island)
///   • Catalyst/Mac → a local notification (so we can test/debug the same flow)
/// Same inputs drive both; updates are throttled so we don't spam.
@MainActor
final class HikeStatusPresenter: NSObject {
    private var routeName = "Hike"
    private var lastKey = ""
    private let notifID = "stayontrack.next-junction"

    #if !targetEnvironment(macCatalyst)
    private var activity: Activity<HikeActivityAttributes>?
    #endif

    // MARK: Lifecycle

    func begin(routeName: String) {
        self.routeName = routeName
        lastKey = ""
        #if targetEnvironment(macCatalyst)
        let center = UNUserNotificationCenter.current()
        center.delegate = self   // so notifications show while the app is foreground
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    /// `active == false` clears the status (no junction within range).
    func update(instruction: String, meters: Int, active: Bool) {
        guard active else { clear(); lastKey = ""; return }
        // Throttle to meaningful changes: instruction, or every ~20 m.
        let key = "\(instruction)-\(meters / 20)"
        guard key != lastKey else { return }
        lastKey = key
        present(instruction: instruction, meters: meters)
    }

    func end() { clear(); lastKey = "" }

    // MARK: Platform backends

    #if targetEnvironment(macCatalyst)

    private func present(instruction: String, meters: Int) {
        let content = UNMutableNotificationContent()
        content.title = instruction
        content.body = "\(meters) m to next junction"
        content.interruptionLevel = .active
        let request = UNNotificationRequest(identifier: notifID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func clear() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [notifID])
        center.removePendingNotificationRequests(withIdentifiers: [notifID])
    }

    #else

    private func present(instruction: String, meters: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = HikeActivityAttributes.ContentState(instruction: instruction, meters: meters)
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            let attributes = HikeActivityAttributes(routeName: routeName)
            activity = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
        }
    }

    private func clear() {
        guard let activity else { return }
        let final = HikeActivityAttributes.ContentState(instruction: "Arrived", meters: 0)
        Task { await activity.end(ActivityContent(state: final, staleDate: nil), dismissalPolicy: .immediate) }
        self.activity = nil
    }

    #endif
}

#if targetEnvironment(macCatalyst)
extension HikeStatusPresenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])   // show even while the app is focused
    }
}
#endif
