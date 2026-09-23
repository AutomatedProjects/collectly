# Collectly

Collectly is a native iOS app for tidying up your photo library one photo at a time.
Swipe **right to keep** and **left to mark for deletion**. You can also file keepers into albums as you go.
Everything stays on the device. There is no backend, no account, and no network use.

## Features (MVP)

- **Swipe review.** Photos appear one card at a time, newest first. Drag right to keep or left to delete. Quick flicks count too.
  The buttons below the card do the same thing, and VoiceOver users get the same choices as accessibility actions.
- **Keep & file.** The album button keeps the current photo and adds it to an album in one step. You can create a new album from the same sheet.
- **Safeguards**
  - **Undo** in the toolbar steps back through your last 100 decisions. It also reverses an album filing made with "keep in album".
  - **Nothing is deleted on swipe.** Swiped-left photos wait in the **To Delete** tab. There you can tap one to keep it instead, or use **Keep All**.
  - Deleting takes **two confirmations**: Collectly's own dialog, then iOS's system prompt.
    Deleted photos go to **Recently Deleted** in Photos and can be recovered for 30 days.
  - If the saved progress file is ever corrupted, Collectly moves it aside instead of overwriting it and starts fresh. It shows a message when this happens.
- **Progress tracking.** A header shows "N of M reviewed", a progress bar, and kept and to-delete counts. Progress is saved after every action and restored on relaunch.
  Once everything is reviewed you can send kept photos back through review.
- **Albums.** Create, rename, and delete albums, and remove photos from them. Deleting an album never deletes photos.
- **Permission handling.** The app has an onboarding screen for first access and a "Photo Access Is Off" screen with an Open Settings link. There is also a Restricted screen.
  With limited access, a banner explains that only the selected photos are visible. Collectly re-checks permission and reloads the library whenever it returns to the foreground.

## Requirements

- Xcode 26 or later (the project uses Xcode 16+ folder-synchronized groups, `objectVersion = 77`)
- iOS 17.0+ deployment target (iPhone and iPad)
- Swift 6 language mode (strict concurrency)
- No third-party dependencies

## Setup

```sh
git clone <repo-url> Collectly
cd Collectly
open Collectly.xcodeproj
```

Select the **Collectly** scheme and a simulator or device, then press Run.
For a physical device, set your Team under *Signing & Capabilities*. You may also need to change the bundle identifier (`com.collectly.Collectly`).

### Demo mode (no real photos needed)

Pass the launch argument `-CollectlyDemoMode` to use 30 generated placeholder photos and in-memory storage. Nothing on the device is read or changed in this mode.
The argument is already in the scheme but turned off: *Product › Scheme › Edit Scheme › Run › Arguments*.

From the command line:

```sh
xcodebuild build -project Collectly.xcodeproj -scheme Collectly \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData
xcrun simctl boot "iPhone 17"
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Collectly.app
xcrun simctl launch booted com.collectly.Collectly -CollectlyDemoMode
```

## Testing

Unit tests use Swift Testing and live in `CollectlyTests/`:

```sh
xcodebuild test -project Collectly.xcodeproj -scheme Collectly \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData
```

In Xcode, press ⌘U. Use any installed iPhone simulator name; `xcrun simctl list devices available` lists them.

The tests cover:

- `ReviewSession`: queueing, decisions, progress, undo (including the cap and stale entries), restore, library reconciliation, and resets
- `AlbumCollection`: name validation (empty, too long, case-insensitive duplicates), add/remove, and cleanup after deletion
- `SwipeDecider`: drag and flick thresholds
- `FilePersistenceStore`: round-trip, missing file, and backup of a corrupted file
- `AppModel` with `MockPhotoLibraryService`: permission flows, persistence across relaunch, keep-in-album and its undo, confirmed, cancelled, and failed deletion, and refresh

## Project layout

```
Collectly/
  App/         CollectlyApp (entry point), AppModel (@Observable app state)
  Models/      ReviewDecision, Album, ReviewProgress, PersistedState
  Logic/       ReviewSession, AlbumCollection, SwipeDecider (pure, unit-tested)
  Services/    PhotoLibraryService protocol, SystemPhotoLibraryService (PhotoKit),
               MockPhotoLibraryService, PersistenceStore (JSON file / in-memory)
  Views/       RootView, PermissionView, MainTabView, ReviewView (swipe card),
               PendingDeletionView, AlbumsView (+ detail, name & picker sheets), PhotoImageView
CollectlyTests/  Swift Testing unit tests
```

## MVP decisions & known limitations

These were ambiguous in the brief, so the MVP picks these defaults:

- **Albums are Collectly-local.** They are stored in Collectly's JSON file and reference photos by `PHAsset.localIdentifier`. They are not created in the Photos app. A later version could export them as Photos albums.
- **Deletion is batched.** A swipe only marks a photo. Deleting happens from the To Delete tab.
- **Only still images** are reviewed (`PHAssetMediaType.image`). Videos are not. Review order is newest first.
- **Storage:** `Application Support/Collectly/state.json`. It holds the decisions per photo identifier plus the albums. It is rewritten after each action, which is fine for typical libraries.
  Very large libraries (tens of thousands of photos) may need debounced or incremental saves.
- **Hidden photos under limited access:** decisions and album memberships are kept, but these photos are left out of the counts. They show up again if access is widened.
- **Undo history** lasts only for the current session and is not saved.
- There is no app icon artwork yet. The asset catalog has an empty AppIcon slot.
