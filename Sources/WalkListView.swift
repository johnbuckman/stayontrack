import SwiftUI

/// The list of saved walks: tap a row to export/share its GPX, swipe left to
/// delete. Shown when the user taps "Export GPX" on the finished screen.
struct WalkListView: View {
    @ObservedObject var store: WalkStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.walks.isEmpty {
                    ContentUnavailableView("No saved walks",
                                           systemImage: "figure.hiking",
                                           description: Text("Finish a walk to save it here."))
                } else {
                    List {
                        ForEach(store.walks) { walk in
                            HStack {
                                ShareLink(item: walk.fileURL) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(walk.name).font(.headline).foregroundStyle(.primary)
                                        Text(walk.dateText).font(.caption).foregroundStyle(.secondary)
                                        Text("\(walk.distanceText) · \(walk.durationText) · \(walk.climbText)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .tint(.primary)
                                // Always-visible delete button (reliable on Mac Catalyst).
                                Button(role: .destructive) { store.delete(walk) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .tint(.red)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { store.delete(walk) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button(role: .destructive) { store.delete(walk) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { store.delete(at: $0) }
                    }
                }
            }
            .navigationTitle("Saved walks")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
