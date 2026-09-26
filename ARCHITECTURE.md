# Architecture

Isolate is an Apple Silicon macOS app using SwiftUI, SwiftData, AVFoundation, Core ML, Accelerate, and CryptoKit. `project.yml` is the XcodeGen source of truth; generated Xcode project changes must be regenerated from it.

## Ownership

| Component | Responsibility |
| --- | --- |
| `IsolateApp` / `ContentView` | Main window, commands, shared engine, modal state, SwiftData container |
| `IsolateAppDelegate` | Confirms quitting during a separation or export; waits for a cancelled separation to clean up |
| `ImportCoordinator` | File and folder selection, ordered drops, sequential batch imports, batch progress, failure summaries, persistence |
| `DemucsEngine` actor | Exclusive separation, shared model load and idle release, inference, overlap reconstruction |
| `StreamingAudio` | Bounded decode, downmix and resampling, length checks, normalization statistics, reflected windows, iCloud Drive downloads |
| `StemCache` | Content keys, cache validation, disk-space preflight, staged publication, abandoned-staging sweep, ownership checks |
| `AudioEngineManager` (`@MainActor`) | Playback graph, synchronized starts, controls, metadata tasks, export snapshots |
| `AudioMeterProcessor` | Tap-local FFT, spectrum, waveform and peak readings |
| `AudioExporter` | Independent offline graph, peak-safe stem encoding, ZIP, destination replacement |
| `TrackModel` / `LibraryStore` | SwiftData record for source identity, user title, date and stem paths; the library store, its recovery and the legacy import |
| `ThemeManager` / `AppSettings` | Appearance tokens, Increase Contrast, persisted preferences |
| `NowPlayingManager` / `MenuBarManager` | System media controls, metadata, optional status item |
| `AppMoveHelper` | Offers to move a copy opened from a disk image, including a translocated one, into Applications |

## Import transaction

1. Reserve import state before suspending. Dropped or chosen folders expand to supported audio files off the main actor, in Finder order and without duplicates, and files are processed one at a time. While one separates, iCloud Drive is asked only for the next file, so a cancelled batch does not leave the rest of a folder downloading.
2. Take the single separation slot and sweep `.partial-*` and `.backup-*` folders left in the cache by an interrupted run. The same sweep runs at launch, and is skipped while a separation is running.
3. If the source is an evicted iCloud Drive file, request it and wait, cancellably, with no invented percentage. Without a network connection the import fails after about two seconds with a clear message.
4. Hash the source bytes with the pipeline version (`Isolate-streaming-v4`). Reuse only complete, consistent caches.
5. Before loading the model, compare the space the result needs (frames × 8 bytes × 5 files, plus 64 MiB) with the volume's available capacity, and fail with the numbers if it is short. The check is skipped when the length or capacity is unknown.
6. Wait for the shared model load. Cancelling the import ends the wait at once; the load finishes in the background and the next import reuses it.
7. Decode a float WAV original into a `.partial-<UUID>` staging directory, computing the mono mean and standard deviation in the same streaming pass.
8. Process reflected ten-second windows at five-second hops. Accumulate only the active overlap and write finished hops immediately.
9. Close and validate the four stems and the original, then publish the directory, moving any invalid existing cache aside first. Cancellation or failure removes the unfinished generation.
10. Install the validated audio into the player and insert or update the SwiftData record. A reimport deletes the stem folder it replaced when the cache owns it and no other entry references it. Failures are collected into one summary for the batch; save errors take priority.
11. Release the model 60 seconds after the last separation. A batch keeps it loaded, because each file starts before the timer fires.

Memory for input and output audio is bounded by chunk size rather than track length. Core ML memory is separate and depends on the model and runtime; on the development Mac it measured 1.6–2.7 GB after inference. Temporary and final disk use still scale with track length.

## Playback and UI safety

The audio graph and observable UI state belong to the main actor. Each meter tap owns its mutable FFT state; value snapshots cross back to the UI. Playback completion and metadata tasks carry generation IDs so cancelled or replaced tracks cannot update current state. Artwork decoding and the source-format probe run off the main actor. Remote media callbacks enqueue main-actor work.

Exports snapshot the selected files and controls before the save panel opens, check afterwards that the same track is still loaded, and render on an independent graph in a worker task that can be cancelled. Library deletion is blocked while exporting or separating. Existing output files are replaced only after the rendered file or archive is complete.

Quitting asks for confirmation while a separation or export runs. Confirming during a separation cancels it and waits up to 15 seconds for its temporary files to be removed; confirming during an export cancels it and waits up to 5 seconds for its temporary renders to be removed. The exporter stages its output in the volume's item-replacement directory, so nothing partial is left in the destination folder. Separations and exports hold an activity that keeps the Mac from idle-sleeping until they finish.

The app uses one logical main window; automatic window tabbing is disabled. The menu bar item reopens a closed window through the scene's `openWindow`. Hosted tests and `-ui-testing` launches use separate preferences, an in-memory library, and a temporary stem cache.

Track renaming uses a native sheet so its text field can accept keyboard focus while the player is blocked. Decorative corner overlays do not receive pointer events; disabled mixer controls stop participating in keyboard focus. While About, Settings or the delete card covers the separation progress, its cancel button has no keyboard shortcut, so Escape closes the card on top.

## Files and persistence

The library is an explicit SwiftData store at `~/Library/Application Support/Isolate/Library.store`. Builds up to 1.2 used SwiftData's default configuration, which for this unsandboxed app is the shared `~/Library/Application Support/default.store` that other apps also open and migrate. On first launch, `LibraryStore` copies `default.store` and its `-wal`/`-shm` files to a temporary folder, checks with SQLite that the copy has a `ZTRACKMODEL` table with all eight columns, opens only the copy, and inserts rows whose IDs are not already present. The shared file is never opened in place, modified or deleted. Completion is recorded under `didImportLegacyLibraryStore` only after an import succeeds or finds no old library; a failed copy or read is reported and retried at up to three launches.

If `Library.store` cannot be opened and SQLite reports the file damaged (not a database, corrupt, or a failed `quick_check`), it and its sidecar files are moved, never deleted, into `Library Backups/<timestamp>/` beside it and a new store is opened; the main window shows where the backup went at every launch until the notice is closed. If no new store can be created, the originals are moved back. Any other failure (a full disk, permissions, a lock, a store from a newer version) leaves `Library.store` untouched and runs that session in memory with a notice that changes will not be saved and the library will be tried again next launch. Any new `TrackModel` attribute must still be optional or have a default, or ship with a `SchemaMigrationPlan`, or upgraded stores will not open.

Source paths identify library entries; identical bytes at different paths share a cache. Deletion checks both cache ownership and remaining library references. External source audio is never deleted. The app is not App Sandbox enabled; security-scoped access is still balanced for URLs provided by system pickers. Imported sources stay in place and are reread by later launches for metadata and stem rebuilds, so `Info.plist` carries purpose strings for the Desktop, Documents, Downloads, removable-volume and network-volume prompts.

See [AUDIO_ENGINE.md](AUDIO_ENGINE.md), [MODEL.md](MODEL.md), and [RELEASE.md](RELEASE.md) for detailed contracts and verification.
