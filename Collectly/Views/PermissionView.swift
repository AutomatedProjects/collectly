import SwiftUI
import UIKit

/// Onboarding / permission screen shown until Collectly can read the library.
struct PermissionView: View {
    enum Kind {
        case request
        case denied
        case restricted
    }

    let kind: Kind

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 12) {
                Text(title)
                    .font(.title.bold())
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Spacer()
            action
        }
        .padding(32)
    }

    @ViewBuilder
    private var action: some View {
        switch kind {
        case .request:
            Button {
                Task { await model.requestAccess() }
            } label: {
                Text("Allow Photo Access").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .denied:
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Open Settings").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        case .restricted:
            EmptyView()
        }
    }

    private var symbol: String {
        switch kind {
        case .request: "photo.stack"
        case .denied: "lock.shield"
        case .restricted: "hand.raised"
        }
    }

    private var title: String {
        switch kind {
        case .request: "Welcome to Collectly"
        case .denied: "Photo Access Is Off"
        case .restricted: "Photo Access Is Restricted"
        }
    }

    private var message: String {
        switch kind {
        case .request:
            "Review your photos one at a time. Swipe right to keep, swipe left to mark for deletion, and file keepers into albums.\n\nNothing is deleted until you confirm, and your photos never leave your device."
        case .denied:
            "Collectly needs access to your photo library to help you sort it. You can turn on access in Settings › Privacy & Security › Photos."
        case .restricted:
            "Photo library access is restricted on this device, for example by Screen Time or a device management profile."
        }
    }
}

#Preview {
    PermissionView(kind: .request)
        .environment(AppModel(library: MockPhotoLibraryService(status: .notDetermined),
                              persistence: InMemoryPersistenceStore()))
}
