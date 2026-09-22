# Audio engine

## Separation

`ExtAudioFile` decodes supported input into stereo Float32 at 44.1 kHz in 16,384-frame blocks. Normalization uses a mono reference mean and standard deviation. Reflection repeats correctly at both ends even for sources shorter than one model window.

HTDemucs accepts 441,000 frames. Isolate runs sequential predictions with a 220,500-frame hop, applies a Hann window, divides overlap sums by accumulated weights, and writes completed hops to four Float32 WAV files. Returned tensor strides and Float16/Float32 types are respected. Non-finite source/model samples fail the import. The decoded original is preserved for comparison; no automatic filtering or limiting is applied to cached source audio.

Model order is vocals, drums, bass, other. See [MODEL.md](MODEL.md) before replacing the model.

## Playback graph

```text
Vocals → EQ → gain/pan mixer ┐
Drums  → EQ → gain/pan mixer ├→ stem sum ┐
Bass   → EQ → gain/pan mixer ┤          ├→ time/pitch → master EQ → peak limiter → output
Other  → EQ → gain/pan mixer ┘ Original ┘
```

All five players schedule against the same host time. The original and stem sum enter the shared effects path, keeping comparison playback under the same tempo/pitch controls. Original comparison mutes the stem sum. Each channel's audible gain is determined by mute/solo state; solo selection takes priority when any solo is active.

Seeking clamps to the source range, invalidates old completion callbacks, and reschedules all players. Seeking to exactly the end does not schedule a zero-frame segment. Playback stops at completion unless looping is enabled. Playback progress uses the player clock; the UI timer does not generate audio timing.

A–B looping reschedules at the loop start when the player clock reaches the end marker. It is a practice feature, with scheduling latency at the boundary; no seamless/sample-accurate looping guarantee is made.

## Controls and metering

- Faders: −60…+6 dB logarithmic scale, exact unity tick, zero amplitude at the bottom.
- EQ: 100 Hz shelf / 1 kHz parametric / 10 kHz shelf, ±12 dB. Flat EQ and unchanged time/pitch bypass their DSP nodes.
- Pitch: −12…+12 semitones. UI speed presets: 0.5×…1.5×.
- Master output uses Apple's peak limiter. It is not a loudness normalizer or a true-peak mastering guarantee.
- Per-tap processors reuse FFT working buffers and throttle UI readings. Spectrum and waveform readings include both stereo channels, including right-only and opposite-phase signals. The display is a live level visualization, not a stored full-track waveform.

## Exports

| Export | Container | Included controls |
| --- | --- | --- |
| Individual stems | ZIP containing four 24-bit WAV or FLAC files | Optional per-stem EQ; unity gain, centered pan, original timing |
| Current mix | Stereo 44.1 kHz 24-bit WAV | Mute/solo, gain, pan, channel/master EQ, tempo, pitch, limiter; original comparison when selected |

Mix export covers the full track. A fresh AVAudioEngine renders in blocks of up to 4,096 frames with bounded retry handling. Expected duration follows playback rate. The regression suite checks encoding headers, length, audible signal, final transients, mute/pan behavior, and failed-export preservation. No MP3 encoder is implemented.
