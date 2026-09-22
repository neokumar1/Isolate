# Architecture

Isolate is an Apple Silicon macOS app using SwiftUI, SwiftData, AVFoundation, Core ML, Accelerate, and CryptoKit. `project.yml` is the XcodeGen source of truth; generated Xcode project changes must be regenerated from it.

## Ownership

| Component | Responsibility |
| --- | --- |
| `IsolateApp` / `ContentView` | Main window, commands, shared engine, modal state, SwiftData context |
| `ImportCoordinator` | File selection, ordered drops, sequential batch imports, persistence |
| `DemucsEngine` actor | Exclusive separation, model loading, inference, overlap reconstruction |
| `StreamingAudio` | Bounded decode/resampling, normalization statistics, reflected windows |
| `StemCache` | Content keys, cache validation, staged publication and ownership checks |
| `AudioEngineManager` (`@MainActor`) | Playback graph, controls, metadata tasks, export snapshots |
| `AudioMeterProcessor` | Tap-local FFT, spectrum, waveform and peak readings |
| `AudioExporter` | Independent offline graph, encoding, ZIP, destination replacement |
| `TrackModel` | SwiftData record for source identity, user title, date and stem paths |
| `ThemeManager` / `AppSettings` | Persisted appearance and application preferences |
| `NowPlayingManager` / `MenuBarManager` | System media controls, metadata, optional status item |

## Import transaction

1. Reserve import state before suspending; one batch processes files sequentially.
2. Hash source bytes plus a pipeline version. Reuse only complete, consistent caches.
3. Decode a float WAV original into a temporary cache directory, computing mono mean and standard deviation in a streaming pass.
4. Process reflected ten-second windows at five-second hops. Accumulate only the active overlap; write finished hops immediately.
5. Close and validate the four stems and original, then publish the directory. Cancellation/failure removes the unfinished generation.
6. Install validated audio handles into the player; insert/save the SwiftData record. Save errors remain visible.

Memory for input/output audio is bounded by chunk size rather than track length. Core ML memory use is separate and depends on the model/runtime. Temporary and final disk usage still scales with track length.

## Playback and UI safety

The audio graph and observable UI state belong to the main actor. Each meter tap owns its mutable FFT state; value snapshots cross back to the UI. Playback completion and metadata tasks carry generation IDs so cancelled or replaced tracks cannot update current state. Remote media callbacks enqueue main-actor work.

Exports snapshot the selected files and controls and use an independent graph on a worker task. Library deletion is blocked while exporting. Existing output files are replaced only after the rendered file/archive has been created successfully.

The app uses one logical main window. Hosted tests and `-ui-testing` launches use separate preferences, an in-memory library, and a temporary stem cache.

Track renaming uses a native sheet so its text field can accept keyboard focus while the player is blocked. Decorative corner overlays do not receive pointer events; disabled mixer controls stop participating in keyboard focus.

## Files and persistence

Source paths identify library entries; identical bytes at different paths may share a cache. Deletion checks both cache ownership and remaining library references. External source audio is never deleted. The app is not App Sandbox enabled; security-scoped access is still balanced for URLs provided by system pickers.

See [AUDIO_ENGINE.md](AUDIO_ENGINE.md), [MODEL.md](MODEL.md), and [RELEASE.md](RELEASE.md) for detailed contracts and verification.
