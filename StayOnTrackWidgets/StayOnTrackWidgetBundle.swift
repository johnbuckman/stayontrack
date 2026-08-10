import WidgetKit
import SwiftUI

@main
struct StayOnTrackWidgetBundle: WidgetBundle {
    var body: some Widget {
        #if !targetEnvironment(macCatalyst)
        HikeLiveActivity()
        #else
        CatalystPlaceholderWidget()
        #endif
    }
}

#if targetEnvironment(macCatalyst)
// Live Activities don't exist on Mac Catalyst; a trivial widget keeps the
// extension buildable when the app is compiled for Catalyst (dev).
struct CatalystPlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.johnbuckman.stayontrack.placeholder",
                            provider: PlaceholderProvider()) { _ in
            Text("Stay on Track")
        }
    }
}
struct PlaceholderEntry: TimelineEntry { let date: Date }
struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}
#endif
