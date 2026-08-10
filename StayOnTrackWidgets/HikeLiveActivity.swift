#if !targetEnvironment(macCatalyst)
import WidgetKit
import SwiftUI
import ActivityKit

/// The Lock-Screen and Dynamic-Island presentation of the next junction.
struct HikeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HikeActivityAttributes.self) { context in
            // Lock Screen / banner
            HStack(spacing: 14) {
                Image(systemName: "figure.hiking")
                    .font(.title2).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.instruction)
                        .font(.title3.bold()).foregroundStyle(.white)
                    Text("\(context.state.meters) m to next junction")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
                Text("\(context.state.meters)")
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                + Text(" m").font(.headline).foregroundStyle(.white.opacity(0.8))
            }
            .padding()
            .activityBackgroundTint(Color.blue.opacity(0.85))
            .activitySystemActionForegroundColor(.white)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "figure.hiking").font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.meters) m").font(.title3.bold())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.instruction).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("to next junction").font(.caption).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "figure.hiking")
            } compactTrailing: {
                Text("\(context.state.meters)m").monospacedDigit()
            } minimal: {
                Image(systemName: "figure.hiking")
            }
        }
    }
}
#endif
