import SwiftUI

/// Public toilets within ~150 m of the route, ordered by how soon you reach
/// them. While hiking, each row shows the estimated clock time you'll pass it.
/// Mirrors `RestaurantListView`.
struct ToiletListView: View {
    let toilets: [TrailToilet]
    /// Given a distance-along-route (m), the grade-adjusted time INTO the hike
    /// (h:mm from the start) at which you reach it. Nil if unknown.
    let etaIntoHike: (Double) -> String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                if toilets.isEmpty {
                    ContentUnavailableView("No toilets nearby",
                                           systemImage: "toilet",
                                           description: Text("Nothing within 150 m of this trail."))
                } else {
                    List(toilets) { t in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.body.weight(.medium))
                                Text("\(t.alongText) along · \(Int(t.offset)) m off trail")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let eta = etaIntoHike(t.routeDistance) {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(eta).font(.body.monospacedDigit().weight(.semibold))
                                    Text("into hike").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Button {
                                openURL(googleMapsURL(lat: t.lat, lon: t.lon))
                            } label: {
                                Image(systemName: "map.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Open toilet in Google Maps")
                        }
                    }
                }
            }
            .navigationTitle("Nearby toilets")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
