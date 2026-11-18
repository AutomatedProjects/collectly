# Collectly

Collectly is a native iOS app for tidying up your photo library one photo at a time.
Swipe **right to keep** and **left to mark for deletion**. You can also file keepers into albums as you go.
Collectly has no backend and no account, and it never uploads your photos or contacts a server. If you use iCloud Photos, iOS may download photos from iCloud when Collectly shows them (see [Privacy & security](#privacy--security)).

## Features (MVP)

- **Swipe review.** Photos appear one card at a time, newest first. Drag right to keep or left to delete. Quick flicks count too.
  The buttons below the card do the same thing, and VoiceOver users get the same choices as accessibility actions.
- **Keep & file.** The album button keeps the current photo and adds it to an album in one step. You can create a new album from the same sheet.
- **Safeguards**
  - **Undo** in the toolbar steps back through your last 100 decisions. It also reverses an album filing made with "keep in album" (but never removes a photo that was already in that album).
  - Every decision is tied to the photo you acted on. While a swiped card animates away, the buttons and Undo are disabled, so a quick tap can't land on the next photo. The album picker files the photo it was opened for, or nothing.
  - **Nothing is deleted on swipe.** Swiped-left photos wait in the **To Delete** tab. There you can tap one to keep it instead, or use **Keep All** (which asks first).
  - Deleting takes **two confirmations**: Collectly's own dialog, then iOS's system prompt. Only the photos shown when you opened the dialog, and still marked, are deleted.
    Deleted photos go to **Recently Deleted** in Photos and can be recovered for 30 days. With iCloud Photos, the deletion also applies to your other devices.
  - Photos that PhotoKit won't delete (for example, photos synced from a computer) are skipped. Collectly deletes the rest, tells you how many were skipped, and leaves those in To Delete.
  - Saved progress is protected against loss: see [Saved data](#saved-data).
- **Progress tracking.** A header shows "N of M reviewed", a progress bar, and kept and to-delete counts. Progress is saved after every action and restored on relaunch.
  Once everything is reviewed you can send kept photos back through review.
- **Albums.** Create, rename, and delete albums (with a confirmation), and remove photos from them. Deleting an album never deletes photos.
- **Permission handling.** The app has an onboarding screen for first access and a "Photo Access Is Off" screen with an Open Settings link. There is also a Restricted screen.
  With limited access, a banner explains that only the selected photos are visible. Collectly re-checks permission and reloads the library whenever it returns to the foreground, and also when PhotoKit reports a library change. If reloads overlap, only the newest one is applied.

## Privacy & security

- **No network use by Collectly.** The app has no servers, accounts, analytics, or third-party code. `PrivacyInfo.xcprivacy` declares no tracking, no tracking domains, no collected data, and no required-reason APIs. `ITSAppUsesNonExemptEncryption` is `NO` (the app only relies on iOS's built-in data protection).
- **iCloud Photos.** Image requests set `isNetworkAccessAllowed`, so iOS downloads a photo from iCloud when the full-size version isn't on the device. That traffic is between iOS and Apple, not Collectly. Leaving the card or grid cancels the request, including the download. Deleting a photo in Collectly deletes it from iCloud Photos too, so it disappears from your other devices (it's still in Recently Deleted for 30 days).
- **Photo access.** Collectly asks for read/write access because it deletes photos. With limited access it only sees the selected photos.
- **Demo mode** (`-CollectlyDemoMode`) only exists in Debug builds. Release builds ignore the argument.

### Saved data

- Progress lives in `Application Support/Collectly/state.json` with `NSFileProtectionComplete`, so it can't be read while the device is locked. It's included in normal device backups. Saves are encoded and written on a background queue; rapid saves are coalesced, and pending saves are flushed when the app goes to the background.
- On load, the state is validated. A file from a newer app version is left untouched and saving is turned off for the session. Repairable problems (duplicate album IDs, duplicate or empty photo IDs, empty, too long, or clashing album names) are fixed without dropping albums, and the unrepaired original is copied to `state.repaired-<ms>-<UUID>.json` first.
- If the file can't be decoded, it is **moved** to `state.corrupt-<ms>-<UUID>.json` and Collectly starts fresh. Collectly keeps only the newest 3 of these backup files.
- If the file can't be read (for example, the app was prewarmed while the device was locked), Collectly retries when it becomes active. If the read still fails, or the file can't be moved aside, Collectly shows a message and **doesn't save** for the rest of the session, so the original file is never overwritten.
- **Delete marks don't live forever.** A mark only applies to a photo Collectly can see. With full access, marks for photos that are gone (or hidden in Photos) are dropped on the next reload. With limited access, a mark for a deselected photo is kept for 30 days, then dropped. Dropping a mark only returns the photo to review; nothing is ever deleted automatically. Keep decisions for photos that aren't visible are retained, because they are harmless.

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
For a physical device, set your Team under *Signing & Capabilities*. You may also need to change the bundle identifier (`com.ridge.collectly`).

### Demo mode (no real photos needed)

In Debug builds, pass the launch argument `-CollectlyDemoMode` to use 30 generated placeholder photos and in-memory storage. Nothing on the device is read or changed in this mode.
The argument is already in the scheme but turned off: *Product › Scheme › Edit Scheme › Run › Arguments*.

From the command line:

```sh
xcodebuild build -project Collectly.xcodeproj -scheme Collectly \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData
xcrun simctl boot "iPhone 17"
xcrun simctl install booted build/DerivedData/Build/Products/Debug-iphonesimulator/Collectly.app
xcrun simctl launch booted com.ridge.collectly -CollectlyDemoMode
```

## Testing

Unit tests use Swift Testing and live in `CollectlyTests/`:

```sh
xcodebuild test -project Collectly.xcodeproj -scheme Collectly \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build/DerivedData
```

In Xcode, press ⌘U. Use any installed iPhone simulator name; `xcrun simctl list devices available` lists them.

The tests cover:

- `ReviewSession`: queueing, decisions (including decisions bound to a photo ID), progress, undo (including the cap, stale entries, and album filings), restore and Keep All snapshots, library reconciliation, resets, and delete-mark expiry
- `AlbumCollection`: name validation (empty, too long, case-insensitive duplicates), add/remove, and cleanup after deletion
- `PersistedStateValidator`: version checks, duplicate album and photo IDs, album-name repair, and delete-mark dates
- `SwipeDecider`: drag and flick thresholds
- `FilePersistenceStore`: round-trip, coalesced background writes and write-failure reporting, file protection, corrupt-file backup with unique names and pruning, repair backups, and save blocking after unreadable, newer-version, or un-backup-able files
- `PhotoImageRequest`: cancellation of PhotoKit image requests, including races
- `AppModel` with `MockPhotoLibraryService`: permission flows, persistence across relaunch, swipe commits blocking other actions, photo-bound album filing and its undo, confirmed/cancelled/failed/partial deletion limited to the confirmed snapshot, Keep All, overlapping reloads, library-change reloads, delete-mark pruning, and load-failure handling

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
- **Storage:** `Application Support/Collectly/state.json`. It holds the decisions per photo identifier, delete-mark dates, and the albums. It is rewritten (off the main thread, coalesced) after each action, which is fine for typical libraries.
  Very large libraries (tens of thousands of photos) may need incremental saves.
- **Hidden photos under limited access:** keep decisions and album memberships are kept, but these photos are left out of the counts. They show up again if access is widened. Delete marks for them expire after 30 days.
- **Undo history** lasts only for the current session and is not saved.
- There is no app icon artwork yet. The asset catalog has an empty AppIcon slot.
