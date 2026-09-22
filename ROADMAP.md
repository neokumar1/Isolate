# Project status

## Implemented in this checkout

- [x] Native SwiftUI library and Nothing-inspired four-channel mixer.
- [x] Core ML separation with bounded audio buffers, progress, cancellation and validated cache publication.
- [x] Synchronized stems, original comparison, faders, mute/solo, pan, EQ, speed and pitch.
- [x] A–B practice looping.
- [x] SwiftData library, folder grouping, search, rename/delete, metadata/artwork.
- [x] Individual WAV/FLAC stem archives and current-mix WAV export.
- [x] Real audio regression coverage and UI smoke tests.
- [x] Model-aware local packaging and draft-only release automation.
- [x] Updated build/audio/model documentation and bundled third-party notices.

Verification evidence and public-release gates are tracked in [QUALITY_REPORT.md](QUALITY_REPORT.md) and [RELEASE.md](RELEASE.md).

## Future capabilities

These are not part of the current product contract:

- Sample-accurate, seamless DAW-style looping.
- Original-only playback before separation.
- Automatic BPM/key analysis beyond source tags.
- MP3 encoding, multichannel export, or loop-region export.
- Reproducible model conversion tooling and measured performance across a hardware/OS matrix.

Completed features must be validated against behavior, not just checked off after a build.
