import SwiftUI

/// Photos swiped left. Nothing is deleted until the user confirms here, and
/// iOS then asks again before moving them to Recently Deleted.
struct PendingDeletionView: View {
    @Environment(AppModel.self) private var model
    /// Photos shown when the user tapped Delete. Only these (if still
    /// marked) are deleted, even if the list changes while the dialog is open.
    @State private var deletionToConfirm: [String]?
    /// Photos shown when the user tapped Keep All.
    @State private var keepAllToConfirm: [String]?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
    private var photoIDs: [String] { model.session.markedForDeletion }

    var body: some View {
        NavigationStack {
            Group {
                if photoIDs.isEmpty {
                    ContentUnavailableView("Nothing to Delete",
                                           systemImage: "trash.slash",
                                           description: Text("Photos you swipe left on appear here. Nothing is deleted until you confirm."))
                } else {
                    ScrollView {
                        Text("Tap a photo to keep it instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(photoIDs, id: \.self) { photoID in
                                Button {
                                    withAnimation { model.restore(photoID) }
                                } label: {
                                    PhotoThumbnail(photoID: photoID)
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: "arrow.uturn.backward.circle.fill")
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.5))
                                                .font(.title3)
                                                .padding(6)
                                        }
                                }
                                .buttonStyle(.plain)
                                .disabled(model.isDeleting)
                                .accessibilityLabel("Keep this photo instead")
                            }
                        }
                    }
                    .contentMargins(16, for: .scrollContent)
                    .safeAreaInset(edge: .bottom) { deleteButton }
                }
            }
            .navigationTitle("To Delete")
            .toolbar {
                if !photoIDs.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Keep All") { keepAllToConfirm = photoIDs }
                            .disabled(model.isDeleting)
                    }
                }
            }
            .confirmationDialog(deleteQuestion(count: deletionToConfirm?.count ?? 0),
                                isPresented: isPresenting($deletionToConfirm),
                                titleVisibility: .visible,
                                presenting: deletionToConfirm) { ids in
                Button(deleteTitle(count: ids.count), role: .destructive) {
                    Task { await model.confirmDeletion(of: ids) }
                }
            } message: { _ in
                Text("They'll move to Recently Deleted in the Photos app, where you can recover them for 30 days. If you use iCloud Photos, they're also removed from your other devices.")
            }
            .confirmationDialog(keepAllQuestion(count: keepAllToConfirm?.count ?? 0),
                                isPresented: isPresenting($keepAllToConfirm),
                                titleVisibility: .visible,
                                presenting: keepAllToConfirm) { ids in
                Button("Keep All") {
                    withAnimation { model.restoreAll(ids) }
                }
            } message: { _ in
                Text("They'll be marked as kept and removed from this list. Nothing is deleted.")
            }
        }
    }

    private func isPresenting(_ ids: Binding<[String]?>) -> Binding<Bool> {
        Binding(get: { ids.wrappedValue != nil }, set: { if !$0 { ids.wrappedValue = nil } })
    }

    private func deleteTitle(count: Int) -> String {
        count == 1 ? "Delete 1 Photo" : "Delete \(count) Photos"
    }

    private func deleteQuestion(count: Int) -> String {
        count == 1 ? "Delete 1 photo?" : "Delete \(count) photos?"
    }

    private func keepAllQuestion(count: Int) -> String {
        count == 1 ? "Keep 1 photo?" : "Keep all \(count) photos?"
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            deletionToConfirm = photoIDs
        } label: {
            Group {
                if model.isDeleting {
                    ProgressView()
                } else {
                    Label(deleteTitle(count: photoIDs.count), systemImage: "trash")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .disabled(model.isDeleting)
        .padding()
        .background(.bar)
    }
}
