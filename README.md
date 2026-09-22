# Isolate

A native music stem player for Apple Silicon Macs, with a Nothing-inspired mixer interface.

Isolate separates audio into **vocals, drums, bass, and other** using a local Core ML model. Balance the four channels, practice with an A–B loop, compare against the original, and export your work. Audio processing runs on your Mac; no account or cloud service is required.

## Features

- Four synchronized stem channels with calibrated −60 to +6 dB faders, silence at the bottom, mute, solo, and stereo pan.
- Three-band EQ on each stem and the master bus: 100 Hz low shelf, 1 kHz bell, and 10 kHz high shelf. EQ presets and bypass controls.
- Playback speed from 0.5× to 1.5× in preset steps; pitch from −12 to +12 semitones.
- A–B practice loops, original/mix comparison, live spectrum and level meters.
- Batch import, drag and drop, searchable SwiftData library grouped by source folder, and metadata/artwork when present.
- Content-based caching: identical source bytes reuse the same completed separation; unfinished imports never become valid cache entries.
- Four individual **24-bit WAV or FLAC stems in a ZIP**, or a **24-bit WAV mix** with the current channel levels, pan, EQ, speed, and pitch.
- Dark, light, and system appearances; menu bar controls, media keys, and trackpad haptics.

The original is decoded to stereo 44.1 kHz for comparison. Stem exports exclude fader, pan, tempo, and pitch changes; optional stem EQ baking is available in the EQ panel. Mix exports render the full track, including the original when comparison bypass is active. Loop boundaries do not trim exports.

## Requirements and installation

- Apple Silicon Mac; deployment target macOS 14 or later.
- Disk space for the app/model and decoded stems. Cached float audio uses about **106 MB per minute** across four stems and the original.
- A compatible HTDemucs Core ML model, bundled by the release packaging process. A source checkout does not contain model weights.

The public v1.2.7 DMG inspected on September 21, 2026 lacks the separation model. This checkout prepares v1.2.8 with model-aware packaging; it has not been published. See [INSTALL.md](INSTALL.md) and [MODEL.md](MODEL.md) for working source-build instructions, and [QUALITY_REPORT.md](QUALITY_REPORT.md) for verification. Once a complete package is available on [GitHub Releases](https://github.com/neokumar1/Isolate/releases), open its DMG and drag Isolate into Applications.

## Quick start

1. Press **⌘O** or drop local audio files into the window. MP3, WAV, FLAC, M4A/AAC/ALAC, AIFF, and CAF are accepted when supported by the macOS decoder. DRM-protected audio is unsupported.
2. Wait for separation, or press Escape to cancel. Progress and speed are measured from the current job; the first model load can take longer.
3. Adjust the four channels. Double-click a fader, pan dial, or EQ knob to reset it.
4. Set loop markers with **[** and **]**, and toggle looping with **L**.
5. Use **File → Export Stems…** or **File → Export Mix…**.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Space | Play / pause |
| ⌘O | Import audio / batch import |
| ⌘⇧E | Export four stems as ZIP |
| ⌘⇧M | Export the full current mix as WAV |
| ⌘⌥B | Compare original / stem mix |
| 1 / 2 / 3 / 4 | Solo vocals / drums / bass / other |
| V / D / B / O | Mute vocals / drums / bass / other |
| A / I / R | Acapella / instrumental / reset mix |
| [ / ] / L | Set loop start / end / toggle loop |
| ⌘E | Bypass all EQ |
| ⌘1 … ⌘5 | Select header display mode |
| ⌘B | Show / hide library |
| ⌘0 | Show main window |
| ⌘, | Settings and shortcuts |
| ? or / | Shortcut reference card |
| Escape | Dismiss a dialog or cancel separation |

Focused faders and dials also support keyboard adjustment and accessibility actions.

## Development

Requires Xcode 26.2 or later (Swift 6.2 compiler or later) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The project currently uses Swift 5 language mode.

```sh
brew install xcodegen
xcodegen generate
xcodebuild build -project Isolate.xcodeproj -scheme Isolate \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData
open build/DerivedData/Build/Products/Debug/Isolate.app
```

Set up the model using [MODEL.md](MODEL.md) before importing audio. Run checks using [RELEASE.md](RELEASE.md). Architecture and signal flow are documented in [ARCHITECTURE.md](ARCHITECTURE.md) and [AUDIO_ENGINE.md](AUDIO_ENGINE.md).

## Practical limits

Separation quality depends on the source and model; some bleed and artifacts are expected. Processing speed and Core ML compute-device selection depend on hardware, OS, and workload. Isolate does not claim a fixed speed, memory ceiling, or exclusive Neural Engine execution. Looping uses scheduled playback and is intended for practice; it is not a sample-accurate DAW loop engine. BPM and key are read from metadata, with unknown values shown explicitly.

## Credits

App code: [MIT](LICENSE). Model architecture: [Demucs by Meta](https://github.com/facebookresearch/demucs). Typography: DotGothic16 by Fontworks. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Isolate is an independent project and is not affiliated with Nothing or Apple.
