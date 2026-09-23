import SwiftUI
import UIKit

/// The main swipe-to-review screen.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAlbumPicker = false
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
                if session.current != nil {
                    controls
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
                    .disabled(!session.canUndo)
                }
            }
            .sheet(isPresented: $showingAlbumPicker) {
                AlbumPickerSheet(photoID: session.current) { albumID in
                    withAnimation { model.keepCurrent(inAlbum: albumID) }
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
                SwipeCard(photoID: current) { decision in
                    model.decide(decision)
                }
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

    private var controls: some View {
        HStack(spacing: 28) {
            CircleButton(systemImage: "trash", tint: .red, label: "Delete") {
                withAnimation { model.deleteCurrent() }
            }
            CircleButton(systemImage: "rectangle.stack.badge.plus", tint: .accentColor, label: "Keep and Add to Album", size: 52) {
                showingAlbumPicker = true
            }
            CircleButton(systemImage: "heart.fill", tint: .green, label: "Keep") {
                withAnimation { model.keepCurrent() }
            }
        }
    }
}

private struct CircleButton: View {
    let systemImage: String
    let tint: Color
    let label: String
    var size: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
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

    var body: some View {
        GeometryReader { proxy in
            PhotoImageView(photoID: photoID, pointSize: proxy.size, contentMode: .fit)
                .background(Color(.secondarySystemBackground))
                .overlay(alignment: .bottomLeading) {
                    if let date = model.library.creationDate(for: photoID) {
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
    }
}

/// Draggable card: right keeps, left marks for deletion.
struct SwipeCard: View {
    let photoID: String
    let onDecision: (ReviewDecision) -> Void

    @State private var offset: CGSize = .zero
    @State private var isCommitting = false

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
            .accessibilityAction(named: "Keep") { onDecision(.keep) }
            .accessibilityAction(named: "Mark for Deletion") { onDecision(.delete) }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard !isCommitting else { return }
                offset = value.translation
            }
            .onEnded { value in
                guard !isCommitting else { return }
                let decision = SwipeDecider.decision(translation: value.translation.width,
                                                     predictedEndTranslation: value.predictedEndTranslation.width)
                guard let decision else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { offset = .zero }
                    return
                }
                isCommitting = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.easeIn(duration: 0.2)) {
                    offset.width = decision == .keep ? 700 : -700
                }
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    onDecision(decision)
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
