# Verification report — v1.3.0

Verified September 25–27, 2026. Local results are from an Apple silicon MacBook Pro running macOS 27.0 with Xcode 27.0. Hosted results are from GitHub Actions `macos-15` (macOS 15.7, Xcode 26.3) and `macos-26` (macOS 26.6, Xcode 26.6) runners, which fetch the pinned model (`model-htdemucs-v1`, SHA-256 `c497133349d2396a2e865827255d9ceeecc8ce0bee6e25febcac7b04187adc37`). The historical audit notes below are retained from the previous handoff. [Run 36275537518](https://github.com/neokumar1/Isolate/actions/runs/36275537518) passed both hosted jobs after the audio fixes; the installer-artwork and instructions were then checked locally.

## September 27 publication

The release branch was merged to `main` at `b7dd394b2dbed79bab52e8c8b64fef10eff7c0e9`; [the merged CI run](https://github.com/neokumar1/Isolate/actions/runs/36337596572) passed on macOS 15 and 26. The first attempt of [the tagged release run](https://github.com/neokumar1/Isolate/actions/runs/36338458602) failed one live stem-alignment test on the hosted macOS 26 virtual audio output: two waveform readings were 0.416 and 0.389 against the test's 0.06 maximum. The retry passed all release tests, including actual model inference, and packaged the release. The same Debug alignment test also passed five fresh-process repetitions on a physical macOS 27 Mac with no failures or skips. This supports a host-dependent timing failure, but does not establish that every output device is unaffected.

The published [v1.3.0 release](https://github.com/neokumar1/Isolate/releases/tag/v1.3.0) is public Latest. Its artifacts were downloaded from the GitHub draft and checked before publication: both SHA-256 values matched, the DMG and ZIP passed integrity checks, their app bundles were identical, and both app signatures passed `codesign --verify --deep --strict`. The mounted DMG contained the Applications shortcut, Finder layout, bundled model and licenses; its Finder window was inspected with the status bar visible. The app reports version 1.3.0, minimum macOS 14.0, arm64, and an ad-hoc hardened-runtime signature. An unauthenticated request to the public Latest DMG URL resolved to HTTP 200 after the expected redirect. The release remains **not notarized**.

Published artifact sizes: DMG **160,864,073 bytes**, ZIP **148,389,197 bytes**. SHA-256:

```text
94ec7d120442419fd08fa1e7f8523977fe14a4f56d52c732305503562262d063  Isolate.dmg
96cb568cdd4c8394628f28188b7e1def553855b82b0a9837afc02150ab06d3ac  Isolate-v1.3.0-macOS.zip
```

## September 26 continuation

The continuation found and fixed three additional production defects: nonfinite model-quality diagnostics could trap while converting to `Int`; a failed model load or prediction prevented fallback to another compute path; and unreadable audio headers were detected only after a costly model load. The model release gate now fails incompatible inference unless the older-OS compatibility job explicitly permits safe refusal.

Testing three additional real songs found a fourth defect: denormalization added the mix's DC offset to each of the four stems. The sum therefore contained four times the original offset. Restoring one quarter to each stem improved the affected MP3's reconstruction from **5.6 dB to 28.5 dB**. The cache key advances to v5; existing library stems remain playable, and reimporting a track regenerates them with the corrected algorithm. Analytical Float16/Float32 overlap tests and a real-inference DC-offset test cover the change. The old overlap fixture was corrected to model a four-way split instead of expecting a full copy of the source in every stem.

The app now uses a native `AppIcon.icon` package with four SVG stem layers. Xcode 27 compiles light, dark and tintable icon stacks into `Assets.car`, plus the compatibility `AppIcon.icns`. The default, dark and tinted previews were inspected, as were 16 px and 32 px renders. The standalone ICNS contains all ten standard 16–1024 px representations. macOS's system icon service successfully rendered the packaged app's icon, and its compiled compatibility ICNS was extracted and inspected. The DMG background was regenerated at 1320 × 800 px / 144 dpi with a drag arrow and system requirements. A mounted Finder-window inspection caught footer text hidden by Finder's status bar; the final image shows both requirements lines unobstructed. Xcode 26.3's asset agent crashed on the layered icon on the hosted macOS 15 image, so only that CI job builds with the committed compatibility ICNS; macOS 26 and the release package compile the layered icon. Design references: [Apple Icon Composer](https://developer.apple.com/icon-composer/) and [app-icon integration](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

The earlier local candidate below was built from base commit `13472da629de9edff9f722fe9f3e70496752c9c7` plus the v1.3.0 release-branch changes. It is distinct from the published GitHub Actions package above.

| Current-checkout check | Result |
| --- | --- |
| Release build and packaging | Passed; arm64, version 1.3.0, bundled model and licenses |
| DMG / ZIP contents | Identical app contents; valid `/Applications` symlink, visible install artwork, bundled model; image verified and mounted read-only; both app signatures passed |
| Signature | `codesign --verify --deep --strict` passed; ad hoc with hardened runtime; **not notarized** |
| Bundled model | Reference hashes and input/output tensor contract passed |
| Icon resources | Four vectors; Aqua, Dark Aqua and tintable icon stacks; compatibility ICNS present |
| Shell, Ruby, YAML, plist, version and whitespace checks | Passed |
| Final model-required unit/audio suite | **200 tests, 0 failures, 0 skips**, including real-music separation; 476.3 seconds |
| Final desktop UI suite | **6 tests, 0 failures, 0 skips**; 157.2 seconds |
| Hosted CI at `de11929` | macOS 15 and 26 Release builds and unit/audio jobs both passed; macOS 26 required real model inference |

Final local installer candidate sizes: app **312,954,459 bytes**, DMG **160,881,848 bytes**, ZIP **148,388,620 bytes**. SHA-256:

```text
b79fc710bda28c37edd178d3bcfb512ca5dd1d6c1843078f7cafacff1e63cc88  Isolate.dmg
c8fdcf291b4ee8bbf567f819de728c0b9e5a9594f469e124af14f8a5bf39b638  Isolate-v1.3.0-macOS.zip
```

The build emits Xcode's unrelated App Intents metadata notice and an outdated iOS simulator-service diagnostic on this Mac; native macOS builds succeed. Negative tests deliberately emit decoder and library-open errors while checking safe recovery. The unit result records 16 internal thread-priority inversion warnings during audio tests, and the UI result records one. These checks establish passing behavior, not a silent console or a proof that every scheduling path is optimal.

An earlier UI attempt closed the Save dialog before its button could be queried; the WAV had actually exported and appeared in Finder. The export workflow then passed in isolation, followed by a clean pass of all six UI tests. The final result bundle is `/private/tmp/IsolateLaunchReview-ui-verified.xcresult`; the unit bundle is `/private/tmp/IsolateLaunchReview-final-verified.xcresult`.

## Current real-music results

Three additional sources were copied from the owner's music library into a temporary test folder; the originals were only read. Every output contained four finite stereo stems at 44.1 kHz, with matching source lengths and nonzero energy in all four stems.

| Source | Length | Separation time | Speed | Stems → mix reconstruction |
| --- | --- | --- | --- | --- |
| MP3 with measurable DC offset and punctuation in its filename | 3:37 | 71.1 s | 3.1× realtime | 28.5 dB |
| M4A | 2:13 | 43.2 s | 3.1× realtime | 22.9 dB |
| Long MP3 | 9:08 | 170.8 s | 3.2× realtime | 30.3 dB |

These values measure reconstruction and processing time, not perceptual stem isolation. The largest stem peak was 1.389; floating-point caches preserve it, and the separately tested export path prevents 24-bit clipping. The real-music verifier still checks every sample for finiteness, but now calls XCTest only for failures rather than millions of successful per-sample assertions.

## Earlier branch results (before this continuation)

| Check | Result |
| --- | --- |
| Unit and audio regression suite, model required (local, macOS 27) | **192 tests, 0 failures**; 1 skipped: the opt-in real-music test |
| Same suite on hosted macOS 26 | **192 tests, 0 failures**; 4 skipped: the real-music test, and 3 double-click tests because this host does not deliver synthetic mouse events |
| Same suite on hosted macOS 15 | **See CI on the release pull request.** The model self-test refuses the model here (3.3 dB on every compute path), so inference tests skip with that reason |
| Desktop UI suite (local) | **5 tests, 0 failures** |
| Real music, three songs (local) | **All separated**; stems reconstruct each mix at 28.6–32.9 dB (table below) |
| Release build (arm64) | Passed with no warnings in `Sources/` |
| Local package, `scripts/package_release.sh v1.3.0` | Passed: `Isolate.dmg` 160,101,439 bytes, app 312,945,036 bytes, version 1.3.0, ad-hoc signature with the hardened runtime, `codesign --verify --deep --strict` passes, model and licenses bundled |
| Reference model hashes and tensor contract | Passed for the installed model and the hosted archive (downloaded and re-checked) |

The UI workflow imports synthetic audio through the system file picker and waits for real Core ML separation. It then plays and pauses, solos and mutes every stem, and checks that typing in the library search does not trigger mixer shortcuts. It also checks that Escape over Settings and over About leaves a running separation alone, renames through the native sheet, closes and reopens the main window, exports a 24-bit WAV mix, and deletes the entry while confirming that the source file's bytes are unchanged.

## Earlier real-music separation

The previous handoff recorded these three songs, copied read-only from the owner's library and run through `RealMusicSmokeTests` before this continuation:

| Source | Length | Separation time | Speed | Stems → mix reconstruction |
| --- | --- | --- | --- | --- |
| ALAC `.m4a` (24-bit source) | 4:37 | 1:33 | 3.0× realtime | 32.9 dB |
| MP3 with quotes in its file name | 3:53 | 1:15 | 3.1× realtime | 28.6 dB |
| MP3 | 8:24 | 2:34 | 3.3× realtime | 29.2 dB |

The same songs measured 2.5–2.6× realtime before the model-output loop was rewritten, with **identical** reconstruction and per-stem levels, which confirms the rewrite is bit-exact. Cached stems can peak above full scale (1.34–1.52 here); stem exports lower all four stems together when needed so 24-bit files do not clip. Speed depends on the Mac and on Core ML's scheduling; no fixed speed is claimed.

## Core ML compatibility

A standalone probe separated one built-in ten-second signal with each compute path. Correct output reconstructs the input at about 36–43 dB.

| macOS | CPU only | All compute units | Shipped model vs compiled on that Mac |
| --- | --- | --- | --- |
| 14.8 (hosted) | 3.3 dB ✗ | 43.3 dB ✓ | identical |
| 15.7 (hosted) | 3.3 dB ✗ | 3.3 dB ✗ | identical |
| 26.6 (hosted) | 42.3 dB ✓ | 42.3 dB ✓ | identical |
| 27.0 (local) | 42.2 dB ✓ | 36.8 dB ✓ | identical |

Core ML in macOS 14 and 15 computes this network incorrectly on its CPU path, and on the hosted macOS 15 machine on every path it offered. The fault is in the OS runtime, not the model file. Isolate therefore runs this check whenever it loads the model, tries each compute path, and refuses to separate, with a message to update to macOS 26, if none passes. It never writes stems from a model that failed. See [MODEL.md](MODEL.md).

## Stem synchronization

A polarity null test plays four stems that cancel exactly only while every player renders the same source frame.

- The original fixed 30 ms host-time start left stems 9–42 ms apart.
- A longer host-time lead still misaligned 2 of 9 seeks on this Mac, and most seeks on hosted runners.
- Starting every player at one sample time in the shared render timeline kept every seek, loop wrap and resume aligned on macOS 15, 26 and 27. It also removed a ~50 ms main-thread stall per start.
- At 512 frames and 48 kHz, a loop wrap now leaves a 32–43 ms gap, down from about 100 ms. Loops are not gapless; see [ROADMAP.md](ROADMAP.md).

## Audit process recorded by the previous handoff

1. **Audit.** Eleven specialist audits (engine, separation, library, export, UI, concurrency, design and accessibility, release, performance, tests, robustness) produced 145 findings.
2. **Verification.** After de-duplication, every finding not already corroborated by several auditors was independently verified by adversarial reviewers, two for high-severity claims. 116 held up and 6 were refuted.
3. **Fixes.** The fixes landed in three parallel waves with disjoint file ownership. Each wave ran the full unit suite with real inference before merging.
4. **Final review.** A nine-lens review of the whole branch found 40 more confirmed issues, mostly regressions introduced by the fixes, and all were fixed. The one exception is a decision left to the owner: the tracked `CLAUDE.md` contains personal agent instructions.

## Remaining verification

1. **Separation on real macOS 14 and 15 Macs is unverified.** Hosted machines show Core ML's CPU path is wrong there. Which path a real Mac uses depends on its hardware, so separation may work or may be refused with a clear message. Isolate refuses paths that fail its model check. Test on a physical macOS 14 or 15 Mac, or raise the minimum to macOS 26.
2. **Signing.** Builds are ad-hoc signed and not notarized, and the README walks through first-launch approval. Check the downloaded DMG's first launch on macOS 15 or later and on macOS 14.
3. **Listening.** Reconstruction measures alignment and scale, not how good the stems sound. Listen to representative music before announcing.
4. **Not automated:** physical output-device switching (Bluetooth, USB), media keys and the menu bar controller, double-click reset on macOS 26 (hosted runners there drop synthetic clicks; verified on 15 and 27), and the in-place upgrade from a real pre-1.3 library.
5. **Distribution follow-up.** v1.3.0 is published as Latest with the model, and the cask now uses the published DMG's version and SHA-256. Its Ruby syntax passed, but Homebrew's full audit stopped because this Mac's Command Line Tools are older than Homebrew requires. A clean Homebrew install and the browser-download Gatekeeper flow still need testing on another Mac. See [RELEASE.md](RELEASE.md) and [LAUNCH.md](LAUNCH.md).
