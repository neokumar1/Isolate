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

The locally available artifact audited for this checkout has these SHA-256 values:

```text
8e321470c16930183821c9b63ab058a2b3adc332d7974dc4aabbab15fbbd4ce0  model.mil
efab790ad07d93faeb5a19b6e1eedad8c37ad351563a891a153fce307811c099  weights/weight.bin
```

`scripts/validate_model.swift` requires these hashes and loads the model to check its contract before packaging. These hashes identify the reference artifact; they are not a reproducible training/conversion provenance record. This repository does not yet contain a conversion pipeline or a verified public download for that exact artifact. Document and publish that model input before relying on public release CI.

## Source builds

Place the validated directory at:

```text
~/Library/Application Support/Isolate/HTDemucs.mlmodelc
```

Then validate it from the repository:

```sh
swift scripts/validate_model.swift "$HOME/Library/Application Support/Isolate/HTDemucs.mlmodelc"
```

The app first looks in its bundle, then Application Support. A compatible `HTDemucs_CoreML_FP16.mlpackage` in either location can be compiled on demand. Failed model loading is reported during import; no network download occurs inside the app. Runtime loading validates tensor shapes; release validation also pins the reference hashes.

## CI provisioning

Create a ZIP with `HTDemucs.mlmodelc` at its root using `ditto -c -k --keepParent`. Host that immutable artifact and set repository variables:

- `ISOLATE_MODEL_ARCHIVE_URL`: HTTPS download URL.
- `ISOLATE_MODEL_ARCHIVE_SHA256`: lowercase SHA-256 of the ZIP.

`scripts/fetch_release_model.sh` checks the archive checksum and reference model hashes before installing it into the runner's Application Support directory. It refuses to overwrite an existing model. Release CI sets `TEST_RUNNER_ISOLATE_REQUIRE_MODEL=1`; Xcode forwards it as `ISOLATE_REQUIRE_MODEL=1` to the test process, so missing-model inference cannot silently skip.

When changing model weights, conversion, or output order: review provenance and licenses, update hash validation, increment the cache pipeline version in `StemCache.swift`, and test real inference and source identity before release.
