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

# Run with fake photos (Debug builds only; no permission prompt, in-memory storage)
xcrun simctl launch booted com.ridge.collectly -CollectlyDemoMode
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
  Confirmation dialogs capture the photo IDs when they open (`confirmDeletion(of:)`, `restoreAll(_:)`), and the model only acts on the ones still marked. Photos PhotoKit can't delete are reported, not retried.
- Decisions are bound to a photo ID (`decide(_:for:)`, `keep(_:inAlbum:)`). While `committingPhotoID` is set (a swipe is animating), other decisions and undo are refused. Album filings travel in `ReviewSession.UndoEntry.filedAlbumID`, not a side table.
- Never auto-delete. Stale delete marks are only ever *dropped* (photo returns to review): immediately under full access, after `hiddenDeleteMarkLifetime` under limited access.
- Persistence must be loss-safe. If a load fails in a way that leaves the file as the only good copy (`PersistenceError.blocksSaving`), nothing may save over it: both `FilePersistenceStore` and `AppModel` refuse. Corrupt files are moved to unique `state.corrupt-<ms>-<UUID>.json` names (newest 3 kept). Decoded state goes through `PersistedStateValidator` before use. The file uses `NSFileProtectionComplete`, so `.unreadable` on a prewarmed launch is retried in `reloadLibrary()`.
- Saves are written on a background queue (`StateFileWriter`). In tests, call `flush()` before reading the file back.
- PhotoKit work runs in `Task.detached`. Image requests must stay cancellable through `PhotoImageRequest`.
- Privacy claims must stay accurate. Collectly makes no network requests, but PhotoKit may download iCloud Photos originals and deletions sync through iCloud. Update the README, onboarding text, usage string, and `PrivacyInfo.xcprivacy` together. If you add a required-reason API (file timestamps, UserDefaults, etc.), declare it in the manifest.
- Demo mode is `#if DEBUG` only.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). Mark suites that touch `AppModel` or stores as `@MainActor`.
- The photo-library usage string lives in the build settings (`INFOPLIST_KEY_NSPhotoLibraryUsageDescription`), because the Info.plist is generated.
