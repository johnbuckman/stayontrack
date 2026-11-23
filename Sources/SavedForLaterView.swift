import SwiftUI

/// The walks saved for later: tap "Walk" to load one as the current route,
/// share or delete it otherwise.
struct SavedForLaterView: View {
    @ObservedObject var store: SavedForLaterStore
    /// Load a saved walk as the current route.
    var onWalk: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.walks.isEmpty {
                    ContentUnavailableView("Nothing saved for later",
                                           systemImage: "bookmark",
                                           description: Text("When you open a GPX from another app, choose “Save for later” to keep it here."))
                } else {
                    List {
                        ForEach(store.walks) { walk in
                            HStack(spacing: 12) {
                                NavigationLink {
                                    SavedWalkDetailView(store: store, walk: walk,
                                                        onWalk: { url in onWalk(url); dismiss() })
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Text(walk.name).font(.headline)
                                            if walk.hasNotes {
                                                Image(systemName: "text.bubble").font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .accessibilityLabel("Has comments")
                                            }
                                        }
                                        Text(walk.summaryText).font(.caption).foregroundStyle(.secondary)
                                        Text(walk.addedText).font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button("Walk") { onWalk(walk.fileURL); dismiss() }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                ShareLink(item: walk.fileURL) { Image(systemName: "square.and.arrow.up") }
                                    .buttonStyle(.borderless)
                                // Always-visible delete (swipe is unreliable on Mac Catalyst).
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
                        }
                    }
                }
            }
            .navigationTitle("Saved for later")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { store.refresh() }   // pick up files copied in from outside
        }
    }
}
