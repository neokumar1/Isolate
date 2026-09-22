# Troubleshooting

## Import reports a missing or invalid model

Use a complete packaged release, or follow [MODEL.md](MODEL.md) for a source build. A model with the right filename can still have incompatible tensor shapes or source order. Run `scripts/validate_model.swift` on the intended model. Isolate does not download models automatically.

## Unsupported or damaged audio

Try playing the file in a macOS audio application first. Import supports local MP3, WAV, FLAC, M4A/AAC/ALAC, AIFF, and CAF through the system decoder. DRM-protected files and OGG are unsupported. Renaming an extension does not convert a file.

## Missing stems or moved source files

Isolate attempts to rebuild damaged/missing stems from the original source. Restore that file or reimport it from its new location. Existing complete caches can play without the source, but source metadata may be unavailable. Do not delete the library database as a first troubleshooting step.

## No sound

Check the Mac's output device/volume, Isolate's play state, channel faders, mute/solo buttons, and original comparison. Reset the mix with R. Changing output devices should preserve the current position; pause/resume if the new device is still becoming available. Bluetooth adds latency.

## Separation seems slow

First use includes model loading or compilation. Speed depends on source duration, hardware, available memory, and Core ML's chosen devices. The displayed ETA is computed from completed chunks. Cancellation waits for the current prediction to return before releasing the job and removing partial files.

## Export fails

Check free space and write access to the destination. Export Stems creates a ZIP containing WAV or FLAC files; Export Mix creates a WAV. Existing destinations are replaced only after a complete output has been prepared. MP3 export is not supported.

## App launches without its window

Choose **Window → Show Isolate** (⌘0). The app can continue playing while its window is closed. Open Settings with ⌘, once the main window is visible.

## macOS blocks launch

Verify the download source and review **Privacy & Security → Open Anyway** if you intend to trust that build. A local ad-hoc signature is not Developer ID notarization. Do not turn off Gatekeeper or remove all extended attributes recursively.

## Reporting a problem

Include the app version, macOS version, Mac model, audio format/sample rate/duration, steps, and the visible error. Avoid attaching private or copyrighted source audio; a short synthetic or freely shareable example is preferable.
