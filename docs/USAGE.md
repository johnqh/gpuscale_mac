# gpuscale usage

Complete CLI reference for all four commands. For the AI pipeline specifics see
also [REALESRGAN.md](REALESRGAN.md); for *when* to use which method see
[REASONING.md](REASONING.md).

## Commands at a glance

```
vidscale      <in> <out> [--method auto|resample|realesrgan] [options]   # front door
gpuscale      <in> <out> [options]   # core GPU resample, VIDEO ONLY
gpuscale-full <in> <out> [options]   # gpuscale + original audio (ffmpeg mux)
realesr-video <in> <out> [options]   # AI super-resolution + audio
```

- Use **`vidscale`** unless you have a reason not to — it picks the method
  (`auto`: resample for ≤ 2× upscale, Real-ESRGAN above that) and forwards your
  options to the right backend.
- `gpuscale` writes a **video-only** H.264/MP4; the others carry audio.

## vidscale (front door)

```
vidscale <input> <output> [--method auto|resample|realesrgan] [options]
```

- `--method auto` (default): compares the requested output size to the source
  and routes ≤ 2× upscales to `resample`, larger ones to `realesrgan`. Needs a
  size (`--height/--width/--scale`). Prints the decision.
- `--method resample`: forwards to `gpuscale-full`.
- `--method realesrgan`: forwards to `realesr-video`.

All other options pass straight through to the chosen backend, so everything
below for `gpuscale`/`realesr-video` also works via `vidscale`.

## gpuscale / gpuscale-full (resample)

`gpuscale` writes **video-only**; `gpuscale-full` additionally muxes the original
audio back with ffmpeg (stream copy). Same options otherwise.

## Specifying the output size

Pick **one** of these (dimensions are rounded to even numbers, which H.264
requires):

| Option | Meaning |
|---|---|
| `--height 1080` | Set height; width is derived from the source aspect ratio. |
| `--width 1920` | Set width; height is derived from the source aspect ratio. |
| `--width 1920 --height 1080` | Set both explicitly (may change aspect ratio). |
| `--scale 1.5` | Multiply **both** source dimensions by the factor. |

For a standard 16:9 720p→1080p, `--height 1080` and `--scale 1.5` are
equivalent; prefer `--height` when you want to guarantee a specific output height
regardless of source.

## Options

| Option | Values | Default | Notes |
|---|---|---|---|
| `-w, --width` | pixels | — | Target width. |
| `-H, --height` | pixels | — | Target height. |
| `-s, --scale` | factor (e.g. `1.5`) | — | Uniform scale of both dims. |
| `-b, --bitrate` | Mbps (e.g. `18`) | `18` | Average H.264 bitrate. |
| `-f, --filter` | `lanczos` \| `bicubic` | `lanczos` | Reconstruction kernel. |
| `--sharpen` | `0`–`2` | `0` | Post-resample luminance sharpen (off at 0). |
| `-h, --help` | | | Print help. |
| `-V, --version` | | | Print version. |

### Choosing a bitrate

H.264 at 1080p24:

| Use | Bitrate |
|---|---|
| Visually lossless / archival | 18–25 Mbps |
| High-quality upload (YouTube etc.) | 12–16 Mbps |
| Smaller/streaming | 6–10 Mbps |

If you'd rather target *quality* than bitrate, scale with gpuscale then re-encode
the video with ffmpeg CRF (see [FFMPEG.md](FFMPEG.md) §4).

### Choosing a kernel

- `lanczos` (default): sharpest, best edge fidelity. Occasional faint ringing
  near very high-contrast edges.
- `bicubic`: slightly softer, less ringing. A good choice for noisy or grainy
  sources where Lanczos would emphasize the noise.

`--sharpen` can add a little crispness after a bicubic pass, but go easy
(`0.3`–`0.6`); high values reintroduce halos.

## Examples

```bash
# Recommended end-to-end: 720p -> 1080p with audio
gpuscale-full in.mp4 out_1080p.mp4 --height 1080

# Explicit bitrate and kernel
gpuscale-full in.mp4 out.mp4 --height 1080 --bitrate 16 --filter lanczos

# Scale by factor
gpuscale-full in.mp4 out.mp4 --scale 1.5

# Upscale to 1440p, bicubic + mild sharpen
gpuscale-full in.mp4 out_1440.mp4 --height 1440 --filter bicubic --sharpen 0.4

# 4K at 40 Mbps
gpuscale-full in.mp4 out_4k.mp4 --width 3840 --bitrate 40

# Core binary only (no audio), then mux manually
gpuscale in.mp4 video.mp4 --height 1080
ffmpeg -i video.mp4 -i in.mp4 -map 0:v:0 -map 1:a:0 -c copy final.mp4

# Downscale works too (1080p -> 720p), still anti-aliased
gpuscale-full in_1080.mp4 out_720.mp4 --height 720
```

## realesr-video (AI super-resolution)

```
realesr-video <input> <output> [options]
```

| Option | Values | Default |
|---|---|---|
| `--model` | `animevideov3` \| `x4plus` \| `x4plus-anime` | `animevideov3` |
| `-s, --scale` | `2` \| `3` \| `4` (animevideov3 only) | auto from target |
| `-H, --height` / `-w, --width` | px | — |
| `-b, --bitrate` | Mbps | `18` |
| `--tmpdir` | dir (frames can be tens of GB) | mktemp |
| `--keep-frames` | | off |

```bash
realesr-video in360.mp4 out1080.mp4 --height 1080             # 360p->1080p (exact 3x)
realesr-video in.mp4 out.mp4 --model x4plus --height 1080     # photographic, max detail
vidscale in360.mp4 out1080.mp4 --height 1080                  # or let vidscale route to it
```

Requires the Real-ESRGAN engine (`./scripts/install-realesrgan.sh`). Full details,
model guide, and time/disk costs: [REALESRGAN.md](REALESRGAN.md).

## Progress output

Progress and the final summary are printed to **stderr**, so stdout stays clean
for scripting. A run prints the resolved size/settings, periodic frame counts,
and a final `done — N frames in Ts (F fps)` line.

## Troubleshooting

**`no Metal device available`**
Your Mac/VM has no Metal-capable GPU. gpuscale requires one. (Headless CI VMs
sometimes lack a GPU; run on real hardware.)

**`'gpuscale' not found` from gpuscale-full**
Install the core binary (`./install.sh` or `make install`) so both land on PATH,
or run the binary directly from `.build/release/gpuscale`.

**`'ffmpeg' not found`**
Only `gpuscale-full` and manual muxing need it: `brew install ffmpeg`. The core
`gpuscale` binary runs without ffmpeg.

**Colors look slightly off**
gpuscale disables color management for a faithful passthrough (see
[REASONING.md](REASONING.md)). If your source is HDR/BT.2020, H.264 SDR output
will not carry HDR metadata — for HDR workflows, transcode with ffmpeg and set
the appropriate color tags, or keep the pipeline in an HDR-aware tool.

**Rotated video**
The source track's `preferredTransform` (rotation flag) is preserved on the
output, so portrait/rotated clips keep their orientation.

**Audio/video out of sync**
gpuscale preserves source presentation timestamps. If you see drift, it's almost
always a variable-frame-rate (VFR) source; convert to constant frame rate first:
`ffmpeg -i in.mp4 -vsync cfr -r 24 cfr.mp4`, then run gpuscale on `cfr.mp4`.

## Building from source

```bash
swift build -c release          # -> .build/release/gpuscale
make                            # same
make install PREFIX=~/.local    # install to ~/.local/bin
make test                       # smoke test (needs ffmpeg)
```
