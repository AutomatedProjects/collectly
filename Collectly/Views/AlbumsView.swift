import SwiftUI

struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewAlbum = false

    var body: some View {
        NavigationStack {
            List {
                if !model.albums.isEmpty {
                    Section {
                        ForEach(model.albums) { album in
                            NavigationLink(value: album.id) {
                                AlbumRow(album: album, photoIDs: model.visiblePhotoIDs(in: album))
                            }
                        }
                        .onDelete { offsets in
                            for album in offsets.map({ model.albums[$0] }) {
                                model.deleteAlbum(album.id)
                            }
                        }
                    } footer: {
                        Text("Deleting an album never deletes its photos.")
                    }
                }
            }
            .overlay {
                if model.albums.isEmpty {
                    ContentUnavailableView {
                        Label("No Albums", systemImage: "square.grid.2x2")
                    } description: {
                        Text("While reviewing, tap the album button to keep a photo and file it in one step.")
                    } actions: {
                        Button("New Album") { showingNewAlbum = true }
                    }
                }
            }
            .navigationTitle("Albums")
            .navigationDestination(for: UUID.self) { albumID in
                AlbumDetailView(albumID: albumID)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewAlbum = true
                    } label: {
                        Label("New Album", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingNewAlbum) {
                AlbumNameSheet(title: "New Album", actionTitle: "Create") { name in
                    try model.createAlbum(named: name)
                }
            }
        }
    }
}

private struct AlbumRow: View {
    let album: Album
    let photoIDs: [String]

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover = photoIDs.last {
                    PhotoThumbnail(photoID: cover)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name).font(.headline)
                Text(photoIDs.count == 1 ? "1 photo" : "\(photoIDs.count) photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AlbumDetailView: View {
    let albumID: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showingRename = false
    @State private var showingDeleteConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        if let album = model.albumCollection.album(id: albumID) {
            let photoIDs = model.visiblePhotoIDs(in: album)
            ScrollView {
                if photoIDs.isEmpty {
                    ContentUnavailableView("Empty Album",
                                           systemImage: "photo",
                                           description: Text("Keep photos into this album from the Review tab."))
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(photoIDs, id: \.self) { photoID in
                            PhotoThumbnail(photoID: photoID)
                                .contextMenu {
                                    Button("Remove from Album", systemImage: "minus.circle", role: .destructive) {
                                        model.removePhoto(photoID, fromAlbum: albumID)
                                    }
                                }
                        }
                    }
                    .padding()
                    Text("Touch and hold a photo to remove it from this album.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(album.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Rename", systemImage: "pencil") { showingRename = true }
                        Button("Delete Album", systemImage: "trash", role: .destructive) {
                            showingDeleteConfirmation = true
                        }
                    } label: {
                        Label("Album Options", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingRename) {
                AlbumNameSheet(title: "Rename Album", actionTitle: "Save", initialName: album.name) { name in
                    try model.renameAlbum(albumID, to: name)
                }
            }
            .confirmationDialog("Delete “\(album.name)”?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete Album", role: .destructive) {
                    model.deleteAlbum(albumID)
                    dismiss()
                }
            } message: {
                Text("The photos stay in your library.")
            }
        } else {
            ContentUnavailableView("Album Not Found", systemImage: "questionmark.folder")
        }
    }
}

/// Text-entry sheet used for creating and renaming albums.
struct AlbumNameSheet: View {
    let title: String
    let actionTitle: String
    var initialName = ""
    let onSubmit: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Album Name", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(submit)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, action: submit)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                name = initialName
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        do {
            try onSubmit(name)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Picks (or creates) an album for "keep and add to album".
struct AlbumPickerSheet: View {
    let photoID: String?
    let onSelect: (UUID) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newAlbumName = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New Album", text: $newAlbumName)
                            .submitLabel(.done)
                            .onSubmit(createAndSelect)
                        Button("Create", action: createAndSelect)
                            .disabled(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if !model.albums.isEmpty {
                    Section("Albums") {
                        ForEach(model.albums) { album in
                            Button {
                                select(album.id)
                            } label: {
                                HStack {
                                    Text(album.name).foregroundStyle(.primary)
                                    Spacer()
                                    if let photoID, album.photoIDs.contains(photoID) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Keep in Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func createAndSelect() {
        do {
            let album = try model.createAlbum(named: newAlbumName)
            select(album.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func select(_ albumID: UUID) {
        onSelect(albumID)
        dismiss()
    }
}
