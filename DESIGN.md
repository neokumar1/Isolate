# Isolate - Design System

## Core aesthetic

Isolate looks like a piece of studio hardware: a rigid grid, hairline dividers, dot-matrix type and displays, and custom faders and knobs instead of native sliders. The style is inspired by Nothing's industrial design; Isolate is not affiliated with Nothing. The hardware metaphor overrides standard HIG styling, but never accessibility: contrast, keyboard access, VoiceOver and the system's accessibility settings come first.

## Typography

- **DotGothic16** (Fontworks, SIL Open Font License 1.1) is bundled and registered through `ATSApplicationFontsPath`. It is used for nearly all text: titles, readouts, labels and buttons, usually in capitals.
- SF Symbols and the system font appear only for a few icons and small auxiliary labels.
- Titles that overflow scroll as a marquee. With Reduce Motion on, or when the overflow is small, they truncate with an ellipsis instead and show the full title as a tooltip.

## Color tokens

Every color comes from a semantic token on `ThemeManager`; views do not use literal colors. The themes are **MATCH SYSTEM**, **NOTHING DARK** and **NOTHING LIGHT**.

| Token | Use |
| --- | --- |
| `background`, `surface`, `surfaceSecondary`, `surfaceHover` | Window, cards and modals, control and channel-strip fills, hover |
| `textPrimary`, `textSecondary`, `textMuted` | All readable text, from most to least prominent |
| `textDisabled` | Disabled controls and purely decorative marks; never information |
| `accentRed` | The single accent, reserved for active and interrupting states (see below) |
| `onAccent` | Text and glyphs drawn on an `accentRed` fill |
| `warning` | Amber for comparison and caution: Compare Original, the [A]/[B] loop markers, ALL EQ OFF |
| `hairline`, `border`, `cardBorder` | Dividers and outlines |
| `modalBackdrop`, `modalBackground` | Modal scrim and card |
| `knobFace`, `knobArcTrack`, `faderTrack`, `faderThumb`, `faderThumbStroke`, `faderThumbKnurling`, `spectrumBarDefault` | Hardware controls and displays |

`textPrimary`, `textSecondary`, `textMuted`, `accentRed` and `warning` each measure at least 4.5:1 (the lowest is 4.55:1) against the background, surface, modal and channel-strip fills of their mode, and `onAccent` measures at least 5.9:1 on `accentRed`. Keep new text on these tokens; `textDisabled` and translucent strokes are not for text.

**Increase Contrast.** `ThemeManager` follows System Settings › Accessibility › Display › Increase contrast and updates live. `textSecondary` becomes `textPrimary`, `textMuted` becomes `textSecondary`, hairlines, borders and knob tracks become much more opaque, and fader tick marks switch to the border token.

## Red policy

Red means something is active or needs attention. It is used for engaged solo and mute, LOOP ON and the loop region, the play button, the lit clip LED and signal peaks, values changed from their default (such as pitch or speed), export progress, [RESET], destructive delete, the error toast, the drop target, and separation progress and its cancel button.

Everything at rest is neutral: titles, the clock, resting meters and fader fills, idle buttons, headers and icons. Selected tabs, chips and presets are shown inverted in neutral colors (a `textPrimary` fill with background-colored text), not in red. Compare Original is amber (`warning`), because it marks a comparison rather than an alert.

## Components

- **Channel strips:** four identical strips in model order (vocals, drums, bass, other), each with a meter, a bipolar pan bar, three EQ knobs, a fader with a dB and percentage readout, and M and S buttons.
- **Faders:** −60 to +6 dB on a logarithmic scale with an exact unity tick; the bottom is silence.
- **Knobs and EQ nodes:** ±12 dB with a detent at 0 dB. The trackpad gives an alignment tap only when the gain enters the ±0.25 dB detent.
- **Pan:** moves in 5% steps from the keyboard and snaps exactly to center.
- **Buttons and chips:** small 3–4 pt corner radii, 1 pt outlines, and fills that follow the outline shape.
- **Dot matrix:** the album art renders as a dot matrix (click for full resolution), progress bars are rows of blocks, and the spectrum is 32 block columns.
- **Studio display:** five modes (32-band FFT, stem macros, stem balance, telemetry, equalizer). As space shrinks it drops metadata first, then switches to short tab names, then drops its title.
- **Layout:** a 270 pt library sidebar, the header and studio display, the mixer, and a transport pinned to the bottom that switches between regular, compact and tight sizes so the seek bar stays usable. The minimum window is 960 × 580 pt.
- **Corner brackets** are decorative and never take clicks.

## Motion and feedback

- Animations are short ease-outs of about 0.1 to 0.18 s; the library sidebar snaps without animating. There are no slow springs.
- Reduce Motion stops the title marquee, fades the error toast instead of moving it, and switches the album art without animation.
- Clicks, detents and resets give a trackpad haptic on Macs with a Force Touch trackpad. **Tactile Haptics** in Settings turns them off.

## Accessibility

- Custom controls have VoiceOver labels and values. Faders, knobs, pan bars, the seek bar and EQ nodes are adjustable. Several resets also exist as a named action or a context-menu item: Reset on EQ nodes, Center Pan on pan bars, Reset EQ Gain on knobs, and Clear Loop Markers on LOOP.
- Tabs, chips and presets report their selected state, and errors are announced as well as shown.
- Hit areas are expanded without changing the layout, so small controls respond across their full visible area.
- Every main action has a keyboard shortcut, listed in Settings › Shortcuts and on the shortcut card (?).
