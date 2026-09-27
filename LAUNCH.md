# Isolate 1.3.0 launch kit

Prepared September 26, 2026; the v1.3.0 GitHub release was published September 27. The copy below is for review before posting to social media.

## Before announcing

The public [Latest release](https://github.com/neokumar1/Isolate/releases/latest) is **v1.3.0** and bundles the separation model. Its DMG, ZIP, checksums and Finder installation window were verified after download. The repository's Homebrew cask now uses the published DMG's checksum. Before a social announcement, complete the remaining physical-Mac and fresh-download checks in [QUALITY_REPORT.md](QUALITY_REPORT.md).

The app targets Apple silicon and macOS 14+, with macOS 26+ recommended for separation. Some older macOS compute paths fail the model's built-in check. Distribution is ad-hoc signed and requires first-launch approval; no Developer ID signing or notarization is claimed. Remaining verification limits are recorded in [QUALITY_REPORT.md](QUALITY_REPORT.md).

## LinkedIn post

I built Isolate, a native Mac app for taking songs apart and practicing what you hear.

Drop in an audio file and split it into vocals, drums, bass and other. Solo a bass line, mute the vocals, loop a difficult phrase, or slow it down without changing the pitch. Then export the stems or your own mix.

The separation runs locally on your Mac with HTDemucs through Core ML. No account. No upload.

I wanted it to feel like a piece of studio hardware: dot-matrix type, four channel strips, tactile controls, and Nothing-inspired dark and light themes.

Isolate 1.3.0 is free and open source. Apple silicon required; macOS 26 or later recommended. The download includes the model. This independent project is not affiliated with Nothing or Apple.

Download and first-launch instructions: https://github.com/neokumar1/Isolate

I'd love to hear what you use it to practice.

## Short post

I built Isolate for Mac: split songs into vocals, drums, bass and other, then solo, loop, slow down and export. Runs locally. Free and open source. Apple silicon; macOS 26+ recommended.

https://github.com/neokumar1/Isolate

## Images and alt text

- Lead image: [full dark mixer](Assets/screenshot-dark.png). The matching [social preview](Assets/social_preview.png) now preserves the whole window, including the transport and export controls.
- Second image: [full light mixer](Assets/screenshot-light.png).
- Optional third image: [separation progress](Assets/screenshot-separating.png).
- App icon: [native macOS 27 preview](Assets/AppIcon-macOS27.png), rendered from the bundled layered icon.
- Alt text: “Isolate's four-channel audio mixer on macOS, with vocals, drums, bass and other stems, EQ knobs, level faders, a spectrum display and playback controls.”

The screenshots show the synthetic Isolate Demo. Keep personal libraries and copyrighted song artwork out of public captures. For a video, use audio you own or have permission to share.

## 25-second demo outline

1. 0–5 seconds: show the loaded demo and start playback.
2. 5–12 seconds: solo drums, then bass, then restore the full mix.
3. 12–18 seconds: set a loop and reduce speed to 0.75×.
4. 18–25 seconds: show Export Mix and the light theme; end on the repository URL.

Use a real screen recording. Do not imply that the separation happens instantly, that stems are artifact-free, or that all Macs separate at the same speed.
