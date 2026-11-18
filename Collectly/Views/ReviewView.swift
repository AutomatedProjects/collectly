import SwiftUI
import UIKit

/// The main swipe-to-review screen.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    /// The photo the album picker was opened for. Filing applies to this
    /// photo only, even if the queue moves on while the sheet is open.
    @State private var albumPickerPhoto: AlbumPickerTarget?
    @State private var showingResetConfirmation = false

    private var session: ReviewSession { model.session }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if model.authorization == .limited {
                    LimitedAccessBanner()
                }
                ProgressHeader(progress: session.progress)
                content
                    .frame(maxHeight: .infinity)
                if let current = session.current {
                    controls(for: current)
                }
            }
            .padding()
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { model.undo() }
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!session.canUndo || model.isCommittingSwipe)
                }
            }
            .sheet(item: $albumPickerPhoto) { target in
                AlbumPickerSheet(photoID: target.photoID) { albumID in
                    withAnimation { model.keep(target.photoID, inAlbum: albumID) }
                }
            }
            .confirmationDialog("Review kept photos again?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                Button("Review Kept Photos Again") { model.resetKeptDecisions() }
            } message: {
                Text("Kept photos go back into the review queue. Album contents and photos marked for deletion aren't affected.")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loadState != .loaded {
            ProgressView("Loading photos…")
        } else if let current = session.current {
            ZStack {
                if let next = session.upNext {
                    PhotoCard(photoID: next)
                        .scaleEffect(0.94)
                        .opacity(0.6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                SwipeCard(photoID: current)
                    .id(current)
                .transition(.opacity)
            }
        } else if session.progress.total == 0 {
            ContentUnavailableView("No Photos",
                                   systemImage: "photo.on.rectangle",
                                   description: Text("Photos you take or allow Collectly to access will appear here."))
        } else {
            ContentUnavailableView {
                Label("All Caught Up", systemImage: "checkmark.seal")
            } description: {
                Text("You reviewed all \(session.progress.total) photos. \(session.progress.markedForDeletion) are waiting in To Delete.")
            } actions: {
                if session.progress.kept > 0 {
                    Button("Review Kept Photos Again") { showingResetConfirmation = true }
                }
            }
        }
    }

    private func controls(for photoID: String) -> some View {
        HStack(spacing: 28) {
            CircleButton(systemImage: "trash", tint: .red, label: "Delete") {
                withAnimation { model.decide(.delete, for: photoID) }
            }
            CircleButton(systemImage: "rectangle.stack.badge.plus", tint: .accentColor, label: "Keep and Add to Album", size: 52) {
                albumPickerPhoto = AlbumPickerTarget(photoID: photoID)
            }
            CircleButton(systemImage: "heart.fill", tint: .green, label: "Keep") {
                withAnimation { model.decide(.keep, for: photoID) }
            }
        }
        .disabled(model.isCommittingSwipe)
    }
}

private struct AlbumPickerTarget: Identifiable {
    let photoID: String
    var id: String { photoID }
}

private struct CircleButton: View {
    let systemImage: String
    let tint: Color
    let label: String
    var size: CGFloat = 64
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(isEnabled ? tint : .secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(Color(.secondarySystemBackground)))
                .overlay(Circle().strokeBorder(tint.opacity(0.4), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct ProgressHeader: View {
    let progress: ReviewProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(progress.reviewed) of \(progress.total) reviewed")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(progress.fractionComplete, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fractionComplete)
            HStack(spacing: 16) {
                Label("\(progress.kept) kept", systemImage: "heart.fill")
                    .foregroundStyle(.green)
                Label("\(progress.markedForDeletion) to delete", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .font(.caption)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A photo card with its capture date.
struct PhotoCard: View {
    let photoID: String

    @Environment(AppModel.self) private var model
    @State private var creationDate: Date?

    var body: some View {
        GeometryReader { proxy in
            PhotoImageView(photoID: photoID, pointSize: proxy.size, contentMode: .fit)
                .background(Color(.secondarySystemBackground))
                .overlay(alignment: .bottomLeading) {
                    if let date = creationDate {
                        Text(date, format: .dateTime.year().month().day())
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(12)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        }
        .task(id: photoID) {
            creationDate = nil
            let date = await model.library.creationDate(for: photoID)
            guard !Task.isCancelled else { return }
            creationDate = date
        }
    }
}

/// Draggable card: right keeps, left marks for deletion. The decision is
/// bound to this card's photo, so it can't land on the next one.
struct SwipeCard: View {
    let photoID: String

    @Environment(AppModel.self) private var model
    @State private var offset: CGSize = .zero

    var body: some View {
        PhotoCard(photoID: photoID)
            .overlay(alignment: .topLeading) {
                Stamp(text: "KEEP", color: .green)
                    .opacity(offset.width > 0 ? SwipeDecider.hintStrength(translation: offset.width) : 0)
                    .rotationEffect(.degrees(-12))
                    .padding(24)
            }
            .overlay(alignment: .topTrailing) {
                Stamp(text: "DELETE", color: .red)
                    .opacity(offset.width < 0 ? SwipeDecider.hintStrength(translation: offset.width) : 0)
                    .rotationEffect(.degrees(12))
                    .padding(24)
            }
            .offset(x: offset.width, y: offset.height * 0.2)
            .rotationEffect(.degrees(Double(offset.width / 25)))
            .gesture(dragGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo")
            .accessibilityHint("Swipe right to keep, left to mark for deletion.")
            .accessibilityAction(named: "Keep") { model.decide(.keep, for: photoID) }
            .accessibilityAction(named: "Mark for Deletion") { model.decide(.delete, for: photoID) }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !model.isCommittingSwipe else { return }
                offset = value.translation
            }
            .onEnded { value in
                guard !model.isCommittingSwipe else { return }
                let decision = SwipeDecider.decision(translation: value.translation.width,
                                                     predictedEndTranslation: value.predictedEndTranslation.width)
                guard let decision, model.beginSwipe(on: photoID) else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
                    return
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeIn(duration: 0.2)) {
                    offset.width = decision == .keep ? 700 : -700
                }
                let (model, photoID) = (model, photoID)
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    withAnimation { model.finishSwipe(decision, on: photoID) }
                }
            }
    }
}

private struct Stamp: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.title.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(color, lineWidth: 4))
    }
}

struct LimitedAccessBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Collectly can only see the photos you selected.")
                .font(.footnote)
            Spacer(minLength: 0)
            Button("Manage") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ReviewView()
        .environment(AppModel(library: MockPhotoLibraryService(), persistence: InMemoryPersistenceStore()))
}
