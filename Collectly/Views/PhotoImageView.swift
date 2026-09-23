import SwiftUI
import UIKit

/// Loads and displays a library photo by identifier.
struct PhotoImageView: View {
    let photoID: String
    /// Display size in points; converted to pixels for the request.
    let pointSize: CGSize
    var contentMode: ContentMode = .fill

    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: photoID) {
            image = nil
            failed = false
            let width = max(pointSize.width, 100) * displayScale
            let height = max(pointSize.height, 100) * displayScale
            let loaded = await model.library.image(for: photoID, targetSize: CGSize(width: width, height: height))
            guard !Task.isCancelled else { return }
            image = loaded
            failed = loaded == nil
        }
    }
}

/// Square grid thumbnail.
struct PhotoThumbnail: View {
    let photoID: String

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                PhotoImageView(photoID: photoID, pointSize: CGSize(width: 120, height: 120))
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}
