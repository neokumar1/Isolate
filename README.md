# Isolate

A fast, offline 4-stem audio separator for macOS.

[![macOS 14.0+](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat&logo=apple)](https://github.com/TheConfidentCoder/Isolate)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1--M5-red?style=flat)](https://github.com/TheConfidentCoder/Isolate)
[![License: MIT](https://img.shields.io/badge/License-MIT-gray?style=flat)](LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/TheConfidentCoder/Isolate?style=flat)](https://github.com/TheConfidentCoder/Isolate/releases/latest)

Isolate splits any audio file into four stems: vocals, drums, bass, and other. It runs Demucs v4 directly on your Mac using Core ML and the Apple Neural Engine, so your audio never leaves your machine. No accounts, no cloud APIs, and no subscription.

Once a track is split, you can mute or solo parts, shape each stem with a 3-band EQ, pan channels across stereo, loop specific sections, and export stems as WAV, FLAC, or MP3.

---

## Features

- **Local neural separation**: Splits tracks into vocals, drums, bass, and other in seconds using Core ML on Apple Silicon.
- **Mixer channel strips**: Vertical faders calibrated from -∞ to +6 dB, peak-hold clip LEDs, and double-click to reset to unity (0 dB).
- **3-band EQ per stem**: Low (100 Hz shelf), mid (1 kHz bell), and high (8 kHz shelf) bands with ±12 dB range on every channel.
- **Stereo pan**: Left/right balance with a center snap.
- **Real-time spectrum**: 32-band FFT analyzer shows master mix frequency energy during playback.
- **Stem presets**: Quick buttons for Acapella, Instrumental, Drumless, Karaoke, and Bass & Drums.
- **A-B looping**: Set in and out points on the waveform to loop a section for practice or transcription.
- **Menu bar controller**: Mini player in the macOS menu bar for quick playback control while using other apps.
- **Audio export**: Save separated stems as 24-bit WAV, FLAC, or MP3 files for Logic Pro, Ableton, FL Studio, or DJ software.

---

## Requirements

Isolate is a self-contained macOS app. You do not need to install Python, Node.js, command line tools, or any extra audio packages.

- macOS 14.0 (Sonoma) or newer
- Apple Silicon Mac (M1, M2, M3, M4, M5) or Intel Mac
- 8 GB Unified Memory or more
- ~500 MB disk space

---

## Installation

### Homebrew (recommended)

```bash
brew install --cask TheConfidentCoder/isolate/isolate
```

To update later:

```bash
brew upgrade isolate
```

### Direct download

1. Download `Isolate.dmg` from [Releases](https://github.com/TheConfidentCoder/Isolate/releases/latest).
2. Open the DMG and drag `Isolate.app` into `/Applications`.
3. Open Isolate from your Applications folder.

If macOS shows a warning saying the developer cannot be verified:
- Run `xattr -cr /Applications/Isolate.app` in Terminal, or
- Go to **System Settings** > **Privacy & Security**, scroll down, and click **Open Anyway**.

### One-line terminal install

```bash
curl -fsSL https://raw.githubusercontent.com/TheConfidentCoder/Isolate/main/install.sh | bash
```

---

## Quick start

1. **Open a track**: Drag and drop an audio file into the window, or press `⌘O`. Supported formats include MP3, WAV, FLAC, M4A, AAC, and AIFF.
2. **Wait for separation**: Isolate processes the audio on your Mac. A typical song takes 10 to 25 seconds on Apple Silicon.
3. **Adjust the mix**: Use the four faders to balance levels. Tweak low, mid, and high frequencies on any stem, or click `S` to solo a single part.
4. **Loop a section**: Press `[` to mark the loop start and `]` to mark the loop end. Press `L` to toggle looping on or off.
5. **Export stems**: Press `E` to export the four separated audio files to your disk.

---

## Interface overview

### Top header

- **Track info**: Shows album art, song title, artist, and timing.
- **Spectrum visualizer**: 32-band FFT bars display frequency distribution in real time.
- **Hardware telemetry**: Shows detected chip architecture, active neural units, and output sample rate.
- **Preset macros**:
  - `Acapella`: Solos vocals and mutes the rest.
  - `Instrumental`: Mutes vocals and keeps all instruments.
  - `Drumless`: Mutes drums.
  - `Karaoke`: Lowers vocal volume.
  - `D&B`: Solos drums and bass together.
  - `Reset`: Restores all faders to 0 dB and centers pan dials.
- **Bypass (`B`)**: Toggles between your current stem mix and the original unedited file so you can compare changes.

### Stem channel strips

Each of the four channels (Vocals, Drums, Bass, Other) has:

- **Mini waveform**: Shows audio amplitude for that specific stem.
- **3-band EQ**: `LOW`, `MID`, and `HIGH` rotary controls. Double-click any knob to reset to 0 dB.
- **Pan**: Rotary dial to place the stem left or right in the stereo field.
- **Fader**: Vertical slider with dB graduation marks. Double-click the thumb to return to 0 dB unity.
- **Clip indicator**: Red LED lights for 1.2 seconds if the stem hits 0 dBFS.
- **Mute (`M`) and Solo (`S`)**: Mute the channel or hear it alone.

### Bottom transport bar

The bottom transport bar stays visible at every window size:

- **Waveform scrubber**: Click or drag to jump anywhere in the song.
- **Time readouts**: Shows elapsed time on the left and remaining time on the right.
- **Controls**: Play/pause (`Space`), loop toggle (`L`), and loop in/out points (`[` and `]`).
- **Master volume**: Controls overall output level. An internal limiter set to -0.3 dBFS prevents digital distortion.

### Menu bar mini player

When Isolate is running, a small equalizer icon appears in your macOS menu bar. Click it to pause, resume, adjust volume, or mute stems without bringing the main window forward.

---

## Keyboard shortcuts

| Key | Action |
| :--- | :--- |
| `Space` | Play / pause |
| `1` / `2` / `3` / `4` | Solo Vocals, Drums, Bass, or Other |
| `V` / `D` / `B` / `O` | Mute Vocals, Drums, Bass, or Other |
| `[` / `]` | Set loop start / loop end point |
| `L` | Toggle A-B looping on or off |
| `A` / `I` / `R` | Trigger Acapella, Instrumental, or Reset preset |
| `B` | Toggle bypass (original vs. stem mix) |
| `E` | Open stem export dialog |
| `⌘O` | Open an audio file |
| `?` or `/` | Show keyboard shortcuts card |
| `Esc` | Close open dialog or card |

---

## FAQ

**Does my audio get uploaded to any servers?**  
No. Everything runs locally on your computer. Isolate does not connect to the internet to process audio.

**What file formats can I open?**  
MP3, WAV (16/24/32-bit), FLAC, M4A, AAC, AIFF, and OGG.

**How fast does it split a track?**  
On an M1 or M2 Mac, a 3-minute track typically takes 15 to 25 seconds. On M3, M4, or newer Macs, it takes under 10 seconds.

**Can I import exported stems into my DAW?**  
Yes. When you export, Isolate writes standard 24-bit WAV, FLAC, or MP3 files that you can drop directly into Logic Pro, Ableton, FL Studio, Reaper, or DJ software.

---

## License and credits

- **License**: Released under the [MIT License](LICENSE).
- **Demucs**: Hybrid Transformer Demucs architecture by Alexandre Défossez ([Meta AI Research](https://github.com/facebookresearch/demucs)).
- **Font**: [DotGothic16](https://fonts.google.com/specimen/DotGothic16) by Fontworks Inc.
