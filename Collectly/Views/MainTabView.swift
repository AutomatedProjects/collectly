import SwiftUI

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            ReviewView()
                .tabItem { Label("Review", systemImage: "rectangle.stack") }
            PendingDeletionView()
                .tabItem { Label("To Delete", systemImage: "trash") }
                .badge(model.session.progress.markedForDeletion)
            AlbumsView()
                .tabItem { Label("Albums", systemImage: "square.grid.2x2") }
        }
    }
}
