import SwiftUI

/// Chooses between the permission screens and the main app based on
/// photo library authorization.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.authorization {
            case .notDetermined:
                PermissionView(kind: .request)
            case .denied:
                PermissionView(kind: .denied)
            case .restricted:
                PermissionView(kind: .restricted)
            case .authorized, .limited:
                MainTabView()
            }
        }
        .task { await model.reloadLibrary() }
        .onChange(of: scenePhase) { _, phase in
            // Picks up permission or library changes made in Settings / Photos.
            if phase == .active {
                Task { await model.refresh() }
            }
        }
        .alert("Something Went Wrong", isPresented: alertBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }
}

#Preview("Authorized") {
    RootView()
        .environment(AppModel(library: MockPhotoLibraryService(), persistence: InMemoryPersistenceStore()))
}

#Preview("Not determined") {
    RootView()
        .environment(AppModel(library: MockPhotoLibraryService(status: .notDetermined),
                              persistence: InMemoryPersistenceStore()))
}
