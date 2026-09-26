# Core ML model contract

Model binaries are excluded from Git. The application and release scripts expect a compatible, compiled **HTDemucs.mlmodelc** directory.

| Property | Required value |
| --- | --- |
| Input feature | `audio`, Float32, `[1, 2, 441000]` |
| Output feature | `sources`, Float16 or Float32, `[1, 4, 2, 441000]` |
| Audio | Stereo, 44,100 Hz, 10-second windows |
| Output source axis | **vocals, drums, bass, other** |

The reference model's final gather uses `[3, 0, 1, 2]` to reorder Demucs's original drums/bass/other/vocals order. Using an arbitrary Demucs conversion with the same shapes can silently swap channel labels. Tensor shape validation alone cannot prove source order.

## Reference artifact

The reference artifact has these SHA-256 values:

```text
8e321470c16930183821c9b63ab058a2b3adc332d7974dc4aabbab15fbbd4ce0  model.mil
efab790ad07d93faeb5a19b6e1eedad8c37ad351563a891a153fce307811c099  weights/weight.bin
```

`scripts/validate_model.swift` requires these hashes and loads the model to check its contract before packaging. These hashes identify the reference artifact; they are not a reproducible training or conversion provenance record, and this repository does not contain a conversion pipeline.

The artifact is published as a ZIP with `HTDemucs.mlmodelc` at its root:

| | |
| --- | --- |
| Release | [`model-htdemucs-v1`](https://github.com/neokumar1/Isolate/releases/tag/model-htdemucs-v1) (prerelease) |
| Asset | `HTDemucs-reference.zip`, 144,236,351 bytes |
| URL | `https://github.com/neokumar1/Isolate/releases/download/model-htdemucs-v1/HTDemucs-reference.zip` |
| SHA-256 | `c497133349d2396a2e865827255d9ceeecc8ce0bee6e25febcac7b04187adc37` |

Its tag does not start with `v`, so it never starts the release workflow, and it is a prerelease, so it never becomes the repository's Latest release (which `install.sh` and the README's download link resolve). Keep both properties if the archive is ever replaced, and publish a new tag rather than replacing the asset.

## Source builds

The app looks for the model in its bundle first, then at:

```text
~/Library/Application Support/Isolate/HTDemucs.mlmodelc
```

The simplest way to install it there is the same script CI uses. It downloads the pinned archive, checks its checksum and the reference hashes, and refuses to overwrite an existing model:

```sh
ISOLATE_MODEL_ARCHIVE_URL=https://github.com/neokumar1/Isolate/releases/download/model-htdemucs-v1/HTDemucs-reference.zip \
ISOLATE_MODEL_ARCHIVE_SHA256=c497133349d2396a2e865827255d9ceeecc8ce0bee6e25febcac7b04187adc37 \
  bash scripts/fetch_release_model.sh
```

Set `ISOLATE_MODEL_DESTINATION` to check an archive into another folder without touching an installed model. To validate a model you placed by hand:

```sh
swift scripts/validate_model.swift "$HOME/Library/Application Support/Isolate/HTDemucs.mlmodelc"
```

A compatible `HTDemucs_CoreML_FP16.mlpackage` in either location can be compiled on demand. The app loads the model once per session with `computeUnits = .all`, shares that load between imports, and releases it 60 seconds after the last separation. On the development Mac, the first load by a newly built or updated app took about 17 seconds while Core ML prepared the model; later loads from its compiled cache took 3.2–3.7 seconds. No network download happens inside the app.

Runtime loading validates tensor shapes and then separates a built-in ten-second test signal, requiring the four stems to add back up to it within 20 dB (correct runs measure 36–43 dB). Core ML in macOS 14 and 15 computes this model incorrectly on some compute paths — about 3 dB on the CPU path of both, the same for the shipped model and one compiled on the machine — so each path (`all`, CPU and GPU, CPU and Neural Engine, CPU) is tried until one passes. If none does, imports report that this version of macOS computes the model incorrectly and suggest macOS 26 or later. Release validation also pins the reference hashes. When no model exists, imports report **CoreML Model Not Found**. When a model exists but cannot be used, imports report **Model Could Not Be Loaded** with the model's path and the reason Core ML gave, so a damaged or incompatible model is not mistaken for a missing one.

## CI provisioning

The repository variables `ISOLATE_MODEL_ARCHIVE_URL` (HTTPS) and `ISOLATE_MODEL_ARCHIVE_SHA256` hold the values above. `scripts/fetch_release_model.sh` accepts the checksum in either case, verifies the archive and the reference hashes, and installs the model into the runner's Application Support directory.

- **Build & Test** fetches the model whenever the variables are available, which includes pushes and pull requests from branches of this repository, and sets `TEST_RUNNER_ISOLATE_REQUIRE_MODEL=1`. Pull requests from forks receive no repository variables, so they build and test without the model and the inference tests skip with a notice.
- **Prepare Release Draft** always requires the model.

Xcode forwards `TEST_RUNNER_ISOLATE_REQUIRE_MODEL=1` to the test process as `ISOLATE_REQUIRE_MODEL=1`, so missing-model inference fails instead of silently skipping. Setting only `ISOLATE_REQUIRE_MODEL` in the invoking shell does not enforce this.

To publish a new archive, create the ZIP with `ditto -c -k --keepParent HTDemucs.mlmodelc HTDemucs-reference.zip` outside the repository (`.gitignore` excludes model folders and archives, and GitHub rejects files over 100 MB), attach it to a new non-`v` prerelease, confirm the URL downloads anonymously, and update both variables together.

When changing model weights, conversion, or output order: review provenance and licenses, update hash validation, increment the cache pipeline version in `StemCache.swift` (currently `Isolate-streaming-v4`), and test real inference and source identity before release.
