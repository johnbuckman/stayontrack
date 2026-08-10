#if !targetEnvironment(macCatalyst)
import ActivityKit

/// Shared Live Activity data, used by both the app (to start/update the
/// activity) and the widget extension (to render it). The same source file is
/// a member of both targets so the type matches across them.
struct HikeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var instruction: String     // e.g. "Left"
        var meters: Int             // distance to the next junction
    }
    var routeName: String
}
#endif
