# gpuscale_mac

**Two honest ways to change a video's resolution on macOS — and a front-end that
picks the right one.**

| Method | Command | What it does | Best for |
|---|---|---|---|
| **Resample** | `gpuscale` | GPU (Metal) anti-aliased resize — enlarges existing detail. Fast, faithful, no invention. | Clean sources, moderate changes (≤ ~2×), e.g. **720p→1080p** |
| **AI super-res** | `realesr-video` | Real-ESRGAN reconstructs *new* plausible detail with a neural net. | Low-res sources, big upscales (> 2×), e.g. **360p→1080p** |

```
             ┌───────────────┐
 vidscale ──▶│ --method auto │──┬─▶ gpuscale   (resample, Metal GPU)   ~260 fps
   (front    └───────────────┘  └─▶ realesr-video (Real-ESRGAN, GPU)   ~minutes
    door)                            both carry the original audio across
```

The core resampler does a **direct** source→target resize with a high-quality
**Lanczos**/bicubic kernel on the GPU — no integer-multiply-then-shrink detour,
real anti-aliasing (not nearest-neighbour pixel mapping), and **no color shift**.
The AI path reconstructs detail a resample fundamentally cannot — at the cost of
time, disk, and the honest caveat that the detail is **synthesized, not
recovered**.

> **Which should I use?** If the source is clean and you're bumping resolution by
> up to ~2×, use the resampler — it's near-instant and can't invent anything
> wrong. If you're enlarging a genuinely low-res source by 3×+, use the AI path.
> `vidscale --method auto` applies exactly this rule for you. The full rationale
> (including *why AI "adds detail"* and when it lies) is in
> [`docs/REASONING.md`](docs/REASONING.md).

---

## Requirements

- macOS 13+ with a Metal-capable GPU (Apple Silicon or Intel).
- **Swift toolchain** (Xcode or Command Line Tools) — `install.sh` launches the
  installer if it's missing; or run `xcode-select --install` yourself.
- **ffmpeg** and the **Real-ESRGAN engine** — `install.sh` installs both for you
  (ffmpeg via Homebrew, Real-ESRGAN via `scripts/install-realesrgan.sh`).

## Install

```bash
git clone <this repo> gpuscale_mac && cd gpuscale_mac
./install.sh                      # installs deps (ffmpeg + Real-ESRGAN),
                                  # builds, and installs all commands to /usr/local/bin
# no sudo:
PREFIX=~/.local ./install.sh      # installs to ~/.local/bin (ensure it's on PATH)
```

`install.sh` flags: `--no-deps` (skip dependency install), `--no-realesrgan`
(install ffmpeg but skip the AI engine). ffmpeg install needs
[Homebrew](https://brew.sh); if it's missing the script tells you.

Build/install pieces manually:

```bash
make              # build the gpuscale binary (.build/release/gpuscale)
make install      # install gpuscale + gpuscale-full + realesr-video + vidscale
make realesrgan   # download the Real-ESRGAN GPU engine
make test         # self-test (needs ffmpeg)
```

## Quickstart

```bash
# Let vidscale choose the method from the upscale factor:
vidscale in.mp4 out.mp4 --height 1080

# Force a method:
vidscale in.mp4 out.mp4 --height 1080 --method resample     # GPU resample
vidscale in.mp4 out.mp4 --height 1080 --method realesrgan   # AI super-res

# Use the tools directly:
gpuscale-full in.mp4 out.mp4 --height 1080                  # resample + audio
gpuscale      in.mp4 video_only.mp4 --height 1080           # core, video-only
realesr-video in360.mp4 out1080.mp4 --height 1080           # AI pipeline + audio
```

## Commands

| Command | Role |
|---|---|
| `vidscale` | **Front door.** `--method auto\|resample\|realesrgan`. Forwards options to the backend. |
| `gpuscale` | Core Swift binary: GPU anti-aliased resample, **video-only**. |
| `gpuscale-full` | `gpuscale` + original audio muxed via ffmpeg. |
| `realesr-video` | Real-ESRGAN pipeline: extract → super-resolve → reassemble + audio. |

### Shared options

`-H/--height`, `-w/--width`, `-s/--scale`, `-b/--bitrate` work across the tools.
Resample-only: `-f/--filter lanczos|bicubic`, `--sharpen`.
AI-only: `--model animevideov3|x4plus|x4plus-anime`, `--tmpdir`, `--keep-frames`.

Full reference: [`docs/USAGE.md`](docs/USAGE.md).

## Documentation

- **[docs/REASONING.md](docs/REASONING.md)** — resample vs. AI, the multiply-then-downscale myth, how/why Real-ESRGAN *invents* detail, kernels & anti-aliasing, GPU vs. CPU, color management, with real benchmarks.
- **[docs/REALESRGAN.md](docs/REALESRGAN.md)** — the AI pipeline: models, scales, time/disk costs, examples, caveats.
- **[docs/FFMPEG.md](docs/FFMPEG.md)** — ffmpeg integration: audio, subtitles, re-encoding, batch, and how these tools compare to ffmpeg's own scalers.
- **[docs/USAGE.md](docs/USAGE.md)** — complete CLI reference and troubleshooting.

## Project layout

```
gpuscale_mac/
├── Package.swift                 # SwiftPM manifest
├── Sources/gpuscale/main.swift   # core GPU resampler (Swift / Core Image / Metal)
├── bin/
│   ├── vidscale                  # unified front-end (choose the method)
│   ├── gpuscale-full             # resample + audio
│   └── realesr-video             # AI super-resolution pipeline
├── scripts/install-realesrgan.sh # fetch the Real-ESRGAN GPU engine
├── install.sh · Makefile         # build + install
├── examples/examples.sh          # runnable examples + self-test
├── docs/{REASONING,REALESRGAN,FFMPEG,USAGE}.md
├── LICENSE · README.md
```

## License

MIT — see [LICENSE](LICENSE).
