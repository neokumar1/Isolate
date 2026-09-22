# Production readiness verification — v1.2.8

Verified September 21, 2026 on Apple Silicon, macOS 27.0 (26A428), Xcode 27.0 (27A266a). This report covers the local working tree based on `4e0a222`, including the hardening work already present when this session resumed. Changes and packages remain local.

## Results

| Check | Result |
| --- | --- |
| Unit and audio regression suite, with the model required | **36 passed, 0 failures** |
| Desktop UI suite | **4 passed, 0 failures** |
| Actual Core ML separation | Passed; four finite, stereo stems with the original frame count, including overlap boundaries and cache reuse |
| Release arm64 build | Passed |
| Reference model hashes and tensor contract | Passed |
| Final DMG integrity and all package checksums | Passed |
| Extracted ZIP app signature, version, model hashes and bundled licenses | Passed; ad-hoc signature, version 1.2.8, macOS 14.0 deployment target |
| Shell syntax, cask Ruby syntax, whitespace checks | Passed |

The UI workflow imports synthetic audio through the system picker, waits for separation, plays/pauses, uses mute/reset shortcuts, renames through the native sheet, closes/reopens the main window, exports a 24-bit WAV mix, and deletes the library entry. It verifies the exported frame count and confirms that the source file's bytes are unchanged after deletion. Other UI tests cover empty-library guards, cancelling the picker, dark/light settings, export-format selection, shortcut help, and Escape dismissal. Captured screenshots were inspected.

Audio tests also cover streaming decode/resampling, short-file reflection, incomplete caches, cancellation/retry, on-disk library reload after the original is removed, EQ rendering, positive fader gain, mute/pan/speed, WAV/FLAC bit depth, four-file ZIP exports, Unicode filenames, final audio transients with time/pitch processing, failed-export preservation, and playback completion/seeking. Tests use generated audio and isolated libraries/preferences.

## Corrections in this continuation

- Removed recursive self-assignment from observable pitch/rate setters. The initial playback test crashed with a stack overflow during track loading; repeated resets, playback and invalid-value tests now pass.
- Replaced the rename overlay with a native sheet. The desktop test reproduced a text field that could not take keyboard focus. Typing, saving, and reopening the renamed track now pass.
- Made decorative corner overlays noninteractive and removed disabled mixer controls from keyboard focus. The stray focus ring over the settings modal no longer appears in screenshots.
- Fixed spectrum and waveform meters to include right-channel audio. The new stereo regression failed before the change and passes afterward.
- Bounded exported title components by UTF-8 size while preserving character boundaries, leaving room for stem suffixes on common 255-byte filesystems.
- Fixed a duplicate actor annotation that prevented the test target from compiling, observed the installation-prompt state in its parent view, and forwarded the model-required flag through Xcode's `TEST_RUNNER_` mechanism.
- Updated generated app/version metadata to 1.2.8 and corrected installation guidance against the inspected public artifact.

## Local evidence and artifacts

- Unit results: `/private/tmp/IsolateProductionReady/Logs/Test/Test-Isolate-2026.09.21_21-57-39--0500.xcresult`
- UI results: `/private/tmp/IsolateProductionReady/Logs/Test/Test-Isolate-2026.09.21_21-55-10--0500.xcresult`
- Screenshots: `/private/tmp/isolate-production-final-screenshots/`
- Logs: `/private/tmp/isolate-production-tests.log`, `/private/tmp/isolate-production-ui-tests.log`, `/private/tmp/isolate-production-package.log`
- App packages: `/private/tmp/IsolateRelease-v1.2.8/`
- Prepared model archive: `/private/tmp/IsolateModelForRelease/HTDemucs-reference.zip`
- Model ZIP SHA-256: `c497133349d2396a2e865827255d9ceeecc8ce0bee6e25febcac7b04187adc37`

Use [RELEASE.md](RELEASE.md) to reproduce the checks. Xcode logged a mismatched iOS simulator-service version and skipped unused App Intents metadata extraction; these did not prevent macOS compilation or tests. Core ML may log compute-device fallback diagnostics; the actual inference and finite-output assertions passed. These results do not establish exclusive Neural Engine execution.

## Public-release gates still open

1. **Model provisioning and provenance.** The public [v1.2.7 DMG](https://github.com/neokumar1/Isolate/releases/tag/v1.2.7) was downloaded and inspected read-only. Its resources contain only the icon and font; it has no model and no `CFBundleShortVersionString` entry. The prepared package includes the reference model. GitHub Actions currently has no repository variables configured: publish a verified immutable model archive and set `ISOLATE_MODEL_ARCHIVE_URL` and `ISOLATE_MODEL_ARCHIVE_SHA256`. Review the remaining provenance limits in [MODEL.md](MODEL.md).
2. **Distribution signing.** Local packages are ad-hoc signed. Developer ID signing/notarization and a fresh-download Gatekeeper check are still required for a notarized public release.
3. **Platform and listening checks.** Only this Mac/toolchain was available. Test macOS 14 and a current stable release, physical output-device changes, media keys/menu-bar behavior, and the installation/relaunch path. Listen to representative music to verify source identity and perceptual quality; synthetic audio cannot establish those qualities.
4. **Publication.** Review and publish the completed release, then update the Homebrew cask's version and checksum together. The cask remains pinned to its previously published artifact.

No zero-defect or universal compatibility claim is made. MP3 encoding, automatic BPM/key analysis, seamless sample-accurate loops, and loop-region export remain explicitly outside the current contract in [ROADMAP.md](ROADMAP.md).
