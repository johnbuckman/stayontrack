import SwiftUI

/// One walk saved for later: its figures, a Walk button, and its comments,
/// shown as rendered Markdown and editable as plain text.
struct SavedWalkDetailView: View {
    @ObservedObject var store: SavedForLaterStore
    let walk: LaterWalk
    var onWalk: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(walk.summaryText).font(.subheadline).foregroundStyle(.secondary)
                    Text(walk.addedText).font(.caption).foregroundStyle(.tertiary)
                }
                Button { onWalk(walk.fileURL) } label: {
                    Label("Walk this route", systemImage: "figure.hiking").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)

                Divider()
                HStack {
                    Text("Comments").font(.headline)
                    Spacer()
                    Button(editing ? "Done" : (notes.isEmpty ? "Add" : "Edit")) {
                        if editing { store.setNotes(notes, for: walk) }
                        editing.toggle()
                    }
                }
                if editing {
                    TextEditor(text: $notes)
                        .font(.body.monospaced())
                        .frame(minHeight: 260)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    Text("Markdown works: # heading, - bullet, **bold**, *italic*, [link](https://…)")
                        .font(.caption).foregroundStyle(.secondary)
                } else if notes.isEmpty {
                    Text("No comments yet.").foregroundStyle(.secondary)
                } else {
                    MarkdownText(markdown: notes)
                }
            }
            .padding()
        }
        .navigationTitle(walk.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { notes = store.notes(for: walk) }
        .onDisappear { if editing { store.setNotes(notes, for: walk) } }   // don't lose an unsaved edit
    }
}
