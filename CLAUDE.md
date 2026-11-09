# CLAUDE.md

## What this is
macOS video-rescaling toolkit: a GPU anti-aliased **resampler** (core Swift
binary) plus an AI **super-resolution** pipeline (Real-ESRGAN), fronted by a
chooser. Resample enlarges existing detail faithfully; AI synthesizes new
detail. See README.md for the user-facing story and `docs/` for rationale.

## Stack
- Core binary: Swift 5.9 toolchain, SwiftPM (`Package.swift`), single file
  `Sources/gpuscale/main.swift`. Uses AVFoundation + CoreImage + Metal.
- Wrappers: three Bash scripts in `bin/` (no build step).
- External engine: `realesrgan-ncnn-vulkan` (prebuilt, Vulkan/MoltenVK) — not
  in-repo; fetched by `scripts/install-realesrgan.sh`.
- Platform: macOS 13+ only (hard-fails elsewhere). Needs a Metal GPU; AI/audio
  paths need `ffmpeg`+`ffprobe` (Homebrew).

## Build / test / run (all verified)
```bash
make                      # swift build -c release -> .build/release/gpuscale
make install              # installs 4 commands to $PREFIX/bin (default /usr/local)
make test                 # smoke self-test (needs ffmpeg); == examples/examples.sh --self-test
swift build -c release    # build directly
./install.sh              # deps (ffmpeg + Real-ESRGAN) + build + install; PREFIX=~/.local for no-sudo
```
- No unit-test framework and no linter are configured. `make test` is a
  synthesize-clip-and-check-dimensions smoke test; it is the only test.
- Run from the repo without installing: binary is `.build/release/gpuscale`;
  `vidscale`/`gpuscale-full` locate backends on PATH first, then their own dir.

## Commands (what calls what)
- `vidscale` (`bin/vidscale`): front door. `--method auto|resample|realesrgan`.
  `auto` picks by upscale ratio: ≤2.0× → resample, else realesrgan. Forwards
  remaining flags to the chosen backend; needs `ffprobe` to compute the ratio.
- `gpuscale-full` (`bin/gpuscale-full`): runs `gpuscale` then muxes original
  audio via ffmpeg (`-c copy`, no re-encode).
- `realesr-video` (`bin/realesr-video`): extract frames → Real-ESRGAN → reassemble
  + audio. Models: animevideov3 (default, scales 2/3/4), x4plus, x4plus-anime
  (both scale-4 only).
- `gpuscale`: the core Swift binary, **video-only by design** (audio is left to
  the wrappers / ffmpeg so it stays a composable building block).

## Architecture notes
- `main.swift` is top-level executable code (not a `main()` func); argv parsed
  by hand. `VERSION` constant there (currently "1.0.0") is the source of truth.
- Resize is a single **direct** source→target step via `CILanczosScaleTransform`
  / `CIBicubicScaleTransform`, setting `inputScale = outH/srcH` and
  `inputAspectRatio = (outW/srcW)/scale` to hit exact WxH. No multiply-then-shrink.
- Output dims are rounded to even numbers (H.264 requirement), min 2.
- Pipeline: `AVAssetReader` (decode to BGRA) → CoreImage scale → `AVAssetWriter`
  (H.264, default 18 Mbps). Writer `transform` is set from the source's
  preferredTransform so rotation metadata is preserved.

## Key conventions & gotchas
- **Swift 5 language mode is deliberate** (`swiftLanguageVersions: [.v5]` in
  Package.swift). The AVFoundation APIs used are deprecated but functional under
  the macOS 27 SDK and become hard errors under Swift 6 strict concurrency. Do
  not bump to Swift 6 language mode without reworking those calls.
- **Color management is intentionally disabled**: `CIContext` uses
  `workingColorSpace: NSNull()` and renders with `colorSpace: nil` so the resample
  is a faithful passthrough with no BT.709/sRGB shift. Don't "fix" this.
- Real-ESRGAN engine is located via `REALESRGAN_BIN`, then PATH, then
  `REALESRGAN_DIR` (default `~/.local/share/gpuscale/realesrgan`); models via
  `REALESRGAN_MODELS` or `<bindir>/models`. Staged frames can be tens of GB.
- `-s/--scale` differs by tool: a dimension multiplier in `gpuscale`/`vidscale`,
  but the Real-ESRGAN native model scale (2|3|4) in `realesr-video`.
- `.gitignore` excludes all `*.mp4/*.mov/*.mkv` and `.build/` — don't commit
  media or build output.

## Layout
`Sources/gpuscale/main.swift` (core) · `bin/` (3 wrappers) · `scripts/` (engine
installer) · `examples/examples.sh` (examples + self-test) · `docs/` (REASONING,
REALESRGAN, FFMPEG, USAGE) · `Makefile` · `install.sh` · `Package.swift`.
