# Isolate - Development Guide & Source of Truth

This document serves as the central source of truth for the **Isolate** app. It consolidates the architecture, audio engine, design, roadmap, and user preferences into a single guide.

## Agent Instructions & Rules
* **CRITICAL INSTRUCTION**: Every time the user asks a question or makes a request in the terminal CLI, you MUST ask clarifying questions in a clickable format (using the `ask_question` tool) before beginning work. Aim to ask around 10 questions to ensure 95% confidence in what the user wants, rather than making assumptions.
* **Skills to Leverage**: Utilize the available skills in `/Users/neokumar/.agents/skills/` such as:
    * `swiftui-expert-skill` / `swiftui-pro` (For modern macOS 14 SwiftUI practices and `@Observable`)
    * `investigate` / `qa` (For deep bug squashing and testing)
    * `macos-design-guidelines` (Keep in mind the custom "Nothing" brand overrides standard HIG)
    * `design-html` / `axiom-swiftui` (For precise UI/UX implementation)

---

## Project contract

- Native macOS 14+ app for Apple Silicon; Xcode 26.2+ / Swift 6.2+ compiler, Swift 5 language mode.
- Four stems in model order: vocals, drums, bass, other. SwiftData library and folder grouping.
- Nothing-inspired dark/light/system themes, DotGothic16, horizontal mixer, custom hardware controls.
- Foreground separation with cancellation. Default stem export is 24-bit WAV ZIP; FLAC ZIP and full-mix WAV are also implemented.
- Preserve source audio and user data. Do not commit, push, publish, or replace an installed app unless requested.

## Engineering references

- [ARCHITECTURE.md](ARCHITECTURE.md): ownership, actors, transactions, and persistence.
- [AUDIO_ENGINE.md](AUDIO_ENGINE.md): actual signal path, separation, controls, and export semantics.
- [MODEL.md](MODEL.md): required tensor shapes, source order, reference hashes, and model provisioning.
- [DESIGN.md](DESIGN.md): Nothing-inspired visual system.
- [RELEASE.md](RELEASE.md): test commands, packaging, signing, and public-release gates.
- [QUALITY_REPORT.md](QUALITY_REPORT.md): verification evidence for the current audit.
- [ROADMAP.md](ROADMAP.md): implemented capabilities and explicitly deferred features.

`project.yml` is the source of truth for Xcode configuration. Regenerate after adding source/resources or changing target settings. Keep model binaries and generated distribution artifacts out of Git.

Use measured progress and real metadata; do not invent BPM, key, hardware utilization, speed, memory ceilings, or audio-quality guarantees. Audio working buffers are bounded by chunk length; Core ML allocation and disk use must be assessed separately.
