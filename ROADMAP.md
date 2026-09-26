# Project status

## Implemented in 1.3.0

- [x] Native SwiftUI library and Nothing-inspired four-channel mixer, with dark, light and match-system themes and Increase Contrast support.
- [x] Core ML separation with bounded audio buffers, progress, cancellation, disk-space preflight, iCloud Drive downloads, surround downmix and validated cache publication.
- [x] File and folder import with batch progress and one failure summary per batch.
- [x] Sample-aligned stems, original comparison, faders, mute/solo, pan, three-band EQ on each stem and the master bus, speed and pitch.
- [x] A–B practice looping with a 0.5 s minimum region and a clear-markers shortcut.
- [x] SwiftData library in its own store, with a one-time import from pre-1.3 libraries, backups instead of deletion, folder grouping, search, rename/delete, and metadata/artwork from tags.
- [x] Individual WAV/FLAC stem archives without clipping and current-mix WAV export, with progress and cancellation.
- [x] Real audio regression coverage and UI smoke tests; CI runs real model inference when the model is available.
- [x] Model-bundled, hardened-runtime packaging and draft-only release automation with user-facing notes.

Verification evidence and public-release gates are tracked in [QUALITY_REPORT.md](QUALITY_REPORT.md) and [RELEASE.md](RELEASE.md); user-visible changes are in [CHANGELOG.md](CHANGELOG.md).

## Future capabilities

These are not part of the current product contract:

- Developer ID signing and notarization, so first launch needs no approval.
- Keeping access to imported files across launches, so macOS asks for folder access less often.
- Sample-accurate, seamless DAW-style looping.
- Original-only playback before separation.
- Automatic BPM/key analysis beyond source tags.
- MP3 encoding, multichannel export, or loop-region export.
- Reproducible model conversion tooling and measured performance across a hardware/OS matrix.

Completed features must be validated against behavior, not just checked off after a build.
