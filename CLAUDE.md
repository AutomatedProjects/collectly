# CLAUDE.md

Guidance for AI agents working in this repository.

## What this is

Collectly is a native SwiftUI iOS app (iOS 17+, Swift 6 strict concurrency, no dependencies, no backend). Users swipe through photos to keep or delete them, and can file keepers into local albums. See README.md for features and the MVP decisions.

## Commands

```sh
# Build
xcodebuild build -project Collectly.xcodeproj -scheme Collectly \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData

# Unit tests (Swift Testing)
xcodebuild test -project Collectly.xcodeproj -scheme Collectly \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData

# Run with fake photos (no permission prompt, in-memory storage)
xcrun simctl launch booted com.collectly.Collectly -CollectlyDemoMode
```

Simulator names depend on the installed runtimes; check `xcrun simctl list devices available`. Don't pin `OS=` in the destination, because the patch versions vary.

## Architecture

- `Logic/` holds **pure value types**: `ReviewSession`, `AlbumCollection`, `SwipeDecider`. Put all non-UI rules here and unit-test them.
  `ReviewSession` keeps cached `progress` and `markedForDeletion`. Every mutating method must end by calling `recount()` (or `reconcile`).
- `App/AppModel.swift` is the single `@MainActor @Observable` store. It coordinates the logic types, `PhotoLibraryService`, and `PersistenceStore`, and it calls `persist()` after every user-visible mutation.
  Views read state from it through `@Environment(AppModel.self)` and never talk to PhotoKit directly.
- `Services/` holds protocols with real and mock implementations. `MockPhotoLibraryService` powers previews, tests, and demo mode, so keep it in the app target.
- `Views/` holds SwiftUI only. Keep logic out of views.

## Conventions and gotchas

- The Xcode project uses **folder-synchronized groups**: new files under `Collectly/` or `CollectlyTests/` are picked up automatically. Do not add file references to `project.pbxproj` by hand.
- Swift 6 language mode is enabled. Closures handed to PhotoKit that run off the main thread must be marked `@Sendable` (see `SystemPhotoLibraryService`). Otherwise they inherit `@MainActor` isolation and crash at runtime.
- Deletion safety is a core product promise. Never delete on swipe. Keep both the in-app confirmation and the iOS system prompt. Treat `PhotoLibraryError.userCancelled` as a silent no-op.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). Mark suites that touch `AppModel` or stores as `@MainActor`.
- The photo-library usage string lives in the build settings (`INFOPLIST_KEY_NSPhotoLibraryUsageDescription`), because the Info.plist is generated.
