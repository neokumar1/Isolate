# Audio engine

## Separation

`ExtAudioFile` decodes supported input into stereo Float32 at 44.1 kHz in 16,384-frame blocks. Sources with more than two channels are decoded at their own channel count with an explicit client channel layout (ALAC and AAC otherwise decode in codec-native order) and downmixed by speaker position with `AVAudioConverter`. Files that declare no usable layout get the WAV/FLAC default order, `WAVE_3_0` through `WAVE_7_1`; more than eight channels is refused. For PCM, FLAC and ALAC, whose declared length is exact, a decode that ends more than 1% and more than one second short is refused as damaged; MP3 and AAC lengths can be estimates and are not checked. Core Audio errors are reported in plain language with the four-character code.

Normalization uses a mono reference mean and standard deviation, with stereo energy as a fallback when opposite-phase channels cancel the mono reference. Interior windows read directly into the reused buffer. Reflection repeats correctly at both ends even for sources shorter than one model window.

HTDemucs accepts 441,000 frames. Isolate runs sequential predictions with a 220,500-frame hop, applies a Hann window, divides overlap sums by accumulated weights, and writes completed hops to four Float32 WAV files. Returned tensor strides and Float16/Float32 types are respected, and the output buffer is read once per chunk. Non-finite source or model samples fail the import. The decoded original is preserved for comparison; no automatic filtering or limiting is applied to cached audio. On test songs, the four stems summed back to the decoded original at 28–33 dB signal-to-residual, and cached stems peaked at 1.3–1.5 times full scale, which is why stem export applies a shared gain (see Exports).

Model order is vocals, drums, bass, other. See [MODEL.md](MODEL.md) before replacing the model and [ARCHITECTURE.md](ARCHITECTURE.md) for the import transaction around this loop.

## Playback graph

```text
Vocals → EQ → gain/pan mixer ┐
Drums  → EQ → gain/pan mixer ├→ stem sum ┐
Bass   → EQ → gain/pan mixer ┤          ├→ time/pitch → master EQ → peak limiter → output
Other  → EQ → gain/pan mixer ┘ Original ┘
```

The original and the stem sum meet before the shared effects path, so Compare Original plays under the same speed, pitch and master EQ. Compare Original mutes the stem sum. Each channel's audible gain comes from mute/solo state; solo wins when any solo is active.

Every start from a stopped state (play, seek, loop wrap, autoplay, restart at the end and resume after an output-device change) goes through one path that schedules all five players against the same host time. The lead is sized from the output device's IO buffer (`kAudioDevicePropertyBufferFrameSize`, floored at 512 frames): one cycle per player plus one, a margin of four cycles, the presentation latency and 5 ms. That is about 113 ms at 512 frames and 48 kHz, and about 430 ms at 2,048 frames. `play(at:)` blocks for about one IO cycle per player, so after scheduling, a wall-clock check confirms the calls finished at least one margin before the start time. If they did not, the players are stopped and rescheduled from the current frame with double the lead, up to three attempts. A polarity null test measured a 0-frame offset between stems at 512, 1,024 and 2,048-frame buffers.

Pause calls `engine.pause()`, so every player freezes on the same render cycle, and resume is only `engine.start()`: instant, with no rescheduling. The engine also pauses, releasing the output device, when a track is unloaded, when a seek lands exactly on the end, and 0.5 s after a track finishes so the limiter and time/pitch tails play out. Do not replace this with `engine.pause(); player.play(); engine.start()`: on macOS 27, `play()` on a stopped engine is silently ignored.

Seeking clamps to the source range, invalidates old completion callbacks, stops the players, resets the time/pitch node so no audio from the old position leaks through, and reschedules. Seeking to exactly the end does not schedule a zero-frame segment; with looping on it wraps to the loop start, and with looping off it stops. Playback stops at completion unless looping is enabled. Playback progress uses the player clock; the UI timer does not generate audio timing. Reselecting the loaded track keeps its mix, loop, speed, pitch and position.

A–B looping reschedules at the loop start when the player clock reaches the end marker, keeping the time/pitch tail so the end of the region stays audible. The shortest region is 0.5 s (at most half the track). Setting A at or after B resets B to the end, and setting B at or before A resets A to the start, so a new region begins instead of clamping back into the old one; ⌥L clears both. Looping is a practice feature with scheduling latency at the boundary; no seamless or sample-accurate looping is claimed.

Engine teardown cancels pending work, removes its configuration observer, and releases taps and the graph on the main thread. The playback clock owns its timer on the main actor. This avoids the isolated-deinitializer back-deployment runtime that crashed synchronous tests on macOS 15.

## Controls and metering

- Faders: −60…+6 dB logarithmic scale, exact unity tick, zero amplitude at the bottom.
- EQ: 100 Hz low shelf / 1 kHz parametric / 10 kHz high shelf, ±12 dB, on each stem and the master bus. Flat EQ and unchanged time/pitch bypass their DSP nodes. ⌘E bypasses every stem and master EQ at once.
- Pitch: −12…+12 semitones. UI speed presets: 0.5, 0.75, 0.85, 1, 1.15, 1.25 and 1.5×.
- Master output uses Apple's peak limiter. It is not a loudness normalizer or a true-peak mastering guarantee.
- Meters tap the main mixer (32 bands) and each stem mixer (7 bands). macOS delivers tap buffers of roughly 100 ms; each processor analyses every 1,024-frame FFT hop in the buffer, newest first, taking the per-bin maximum across hops and both channels, so recent audio and short transients register. Processors reuse their FFT working buffers, and readings cross to the main actor as value snapshots. Stem readings are dropped while Compare Original is on. Because pause stops the engine, meters do no work while paused. The display is a live level visualization, not a stored full-track waveform.

## Exports

| Export | Container | Included controls |
| --- | --- | --- |
| Individual stems | ZIP (entries stored, non-ASCII names flagged as UTF-8) of four 24-bit WAV or FLAC files, stereo 44.1 kHz | Channel EQ unless that channel or all EQ is bypassed; unity gain unless one shared gain is needed to keep the loudest stem at −0.1 dBFS; centered pan; original timing |
| Current mix | Stereo 44.1 kHz 24-bit WAV | Mute/solo, gain, pan, channel and master EQ, speed, pitch, limiter. With Compare Original on: the original with master EQ, speed and pitch, named `_Original.wav` |

Exports snapshot the sources, title, format, EQ, speed and pitch before the save panel opens, and refuse with a message if the loaded track changed while it was open. A fresh `AVAudioEngine` renders offline on a worker task in blocks of up to 4,096 frames, checks for cancellation on every block, and reports progress at most once per whole percent. Mix exports cover the full track; loop markers do not trim them.

- **Stem gain.** Each stem is rendered with its EQ to a temporary Float32 WAV and its peak measured. All four are then encoded with one gain, `min(1, 0.98855 / peak)`, so their balance and sum are kept; stems already below −0.1 dBFS are bit-identical to an ungained export. Each temporary file is deleted after it is encoded, so peak temporary use in the system temporary folder is about four Float32 stems plus the encoded files and the ZIP.
- **Mix timing.** With the limiter on, the render runs for the limiter's latency (0.002 s, 88 frames) longer and discards the look-ahead, so a 1× mix is sample-aligned with the source. When speed or pitch is changed, a fixed 4,096-frame (about 93 ms) tail is rendered because the time/pitch unit spreads audio past the stretched length while reporting no latency; such files are `ceil(length / rate) + 4096` frames long.
- **Archive and publication.** `/usr/bin/zip` stores the entries uncompressed and is terminated if the export is cancelled. The finished file is staged in the destination volume's item-replacement directory, then moved or swapped into place, so a cancelled, failed or interrupted export leaves the destination untouched and nothing partial in its folder.
- **File names.** Names come from the library title (keeping its capitalization), with `/ : \ ? * " < > |` and control characters replaced by `_`, leading and trailing dots and spaces trimmed, and the length bounded to 200 UTF-8 bytes on character boundaries.

The regression suite checks encoding headers, lengths, audible signal, final transients with time/pitch, mute and pan, shared stem gain, sample alignment, cancellation, UTF-8 ZIP flags and failed-export preservation. No MP3 encoder is implemented.
