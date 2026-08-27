import SwiftUI

/// Trailside eateries within ~200 m of the route, ordered by how soon you reach
/// them. While hiking, each row shows the estimated clock time you'll pass it.
struct RestaurantListView: View {
    let restaurants: [TrailRestaurant]
    /// Given a distance-along-route (m), the grade-adjusted time INTO the hike
    /// (h:mm from the start) at which you reach it. Nil if unknown.
    let etaIntoHike: (Double) -> String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if restaurants.isEmpty {
                    ContentUnavailableView("No eateries nearby",
                                           systemImage: "fork.knife",
                                           description: Text("Nothing within 200 m of this trail."))
                } else {
                    List(restaurants) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.body.weight(.medium))
                                Text("\(r.alongText) along · \(Int(r.offset)) m off trail")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let eta = etaIntoHike(r.routeDistance) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(eta).font(.body.monospacedDigit().weight(.semibold))
                                    Text("into hike").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nearby food")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
