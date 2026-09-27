# Third-party notices

## Demucs

Isolate uses a Core ML conversion of the Hybrid Transformer Demucs (HTDemucs) model from Meta's Demucs project. Upstream project: <https://github.com/facebookresearch/demucs>. Demucs is released under the MIT License.

The upstream MIT notice is included in `Sources/Resources/Demucs-LICENSE.txt` and bundled in the application. The model is distributed inside release builds and as the `HTDemucs-reference.zip` asset of the `model-htdemucs-v1` prerelease; reference model identification and the remaining conversion-provenance work are documented in [MODEL.md](MODEL.md).

## DotGothic16

DotGothic16 is by Fontworks Inc. (Copyright 2020 The DotGothic16 Project Authors), distributed under the SIL Open Font License 1.1. Its notice is included in `Sources/Resources/DotGothic16-LICENSE.txt` and bundled with the font.

## Platform frameworks

SwiftUI, SwiftData, AVFoundation, Core ML, Accelerate, AppKit and the system audio codecs are provided by Apple. No third-party Swift package dependency is required.

## Trademarks

Isolate's Nothing-inspired visual design does not indicate affiliation with or endorsement by Nothing Technology Limited. Apple, Mac, macOS and Apple silicon are trademarks of Apple Inc.; they are used only to identify compatibility, and Isolate is not affiliated with or endorsed by Apple.
