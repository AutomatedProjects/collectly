import SwiftUI

/// Photos swiped left. Nothing is deleted until the user confirms here, and
/// iOS then asks again before moving them to Recently Deleted.
struct PendingDeletionView: View {
    @Environment(AppModel.self) private var model
    @State private var showingConfirmation = false

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
                        Button("Keep All") { withAnimation { model.restoreAll() } }
                            .disabled(model.isDeleting)
                    }
                }
            }
            .confirmationDialog(confirmationTitle, isPresented: $showingConfirmation, titleVisibility: .visible) {
                Button(deleteTitle, role: .destructive) {
                    Task { await model.confirmDeletion() }
                }
            } message: {
                Text("They'll move to Recently Deleted in the Photos app, where you can recover them for 30 days.")
            }
        }
    }

    private var deleteTitle: String {
        photoIDs.count == 1 ? "Delete 1 Photo" : "Delete \(photoIDs.count) Photos"
    }

    private var confirmationTitle: String {
        photoIDs.count == 1 ? "Delete 1 photo?" : "Delete \(photoIDs.count) photos?"
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            showingConfirmation = true
        } label: {
            Group {
                if model.isDeleting {
                    ProgressView()
                } else {
                    Label(deleteTitle, systemImage: "trash")
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
